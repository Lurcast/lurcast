require "spec"
require "file/tempfile"
require "file_utils"
require "../src/lurcast"

Lurcast.configure_execution_context(2)

class BlockingWriteIO < IO
  getter write_started = Channel(Nil).new(1)
  getter release_write = Channel(Nil).new

  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    @write_started.send(nil)
    @release_write.receive
  end
end

def read_head(socket : TCPSocket) : String
  String.build do |io|
    while line = socket.gets
      io << line << '\n'
      break if line.blank?
    end
  end
end

def uvox_frame(type : UInt16, payload = Bytes.empty) : Bytes
  frame = Bytes.new(7 + payload.size, 0_u8)
  frame[0] = 0x5a_u8
  IO::ByteFormat::BigEndian.encode(type, frame[2, 2])
  IO::ByteFormat::BigEndian.encode(payload.size.to_u16, frame[4, 2])
  payload.copy_to(frame[6, payload.size])
  frame
end

def read_uvox(socket : TCPSocket) : Tuple(UInt16, Bytes)
  header = Bytes.new(6)
  socket.read_fully(header)
  raise "invalid Ultravox sync" unless header[0] == 0x5a
  length = IO::ByteFormat::BigEndian.decode(UInt16, header[4, 2]).to_i
  payload = Bytes.new(length)
  socket.read_fully(payload)
  raise "invalid Ultravox trailer" unless socket.read_byte == 0
  {IO::ByteFormat::BigEndian.decode(UInt16, header[2, 2]), payload}
end

def uvox_metadata(xml : String) : Bytes
  payload = Bytes.new(6 + xml.bytesize, 0_u8)
  payload[1] = 1_u8
  payload[3] = 1_u8
  payload[5] = 1_u8
  xml.to_slice.copy_to(payload[6, xml.bytesize])
  payload
end

def ogg_page(sequence : UInt32, header_type : UInt8, payload : Bytes, serial = 1_u32) : Bytes
  page = Bytes.new(28 + payload.size, 0_u8)
  "OggS".to_slice.copy_to(page[0, 4])
  page[5] = header_type
  IO::ByteFormat::LittleEndian.encode(serial, page[14, 4])
  IO::ByteFormat::LittleEndian.encode(sequence, page[18, 4])
  page[26] = 1_u8
  page[27] = payload.size.to_u8
  payload.copy_to(page[28, payload.size])
  crc = page.reduce(0_u32) do |checksum, byte|
    checksum ^= byte.to_u32 << 24
    8.times { checksum = (checksum << 1) ^ ((checksum & 0x80000000) == 0 ? 0_u32 : 0x04c11db7_u32) }
    checksum
  end
  IO::ByteFormat::LittleEndian.encode(crc, page[22, 4])
  page
end

def mp3_frame(fill = 0_u8) : Bytes
  frame = Bytes.new(417, fill)
  Bytes[0xff, 0xfb, 0x90, 0x64].copy_to(frame)
  frame
end

def free_mp3_frame(fill = 0_u8, padding = false) : Bytes
  frame = Bytes.new(417 + (padding ? 1 : 0), fill)
  Bytes[0xff, 0xfb, padding ? 0x02_u8 : 0_u8, 0x64].copy_to(frame)
  frame
end

def mp3_fixture(name : String) : Bytes
  File.read(File.join(__DIR__, "fixtures", "mp3", name)).to_slice.dup
end

def aac_frame(payload_size = 13) : Bytes
  frame_size = payload_size + 7
  frame = Bytes.new(frame_size, 0_u8)
  frame[0] = 0xff_u8
  frame[1] = 0xf1_u8
  frame[2] = 0x50_u8
  frame[3] = (0x80 | (frame_size >> 11)).to_u8
  frame[4] = (frame_size >> 3).to_u8
  frame[5] = (((frame_size & 7) << 5) | 0x1f).to_u8
  frame[6] = 0xfc_u8
  frame
end

def loas_frame(payload_size = 13) : Bytes
  frame = Bytes.new(payload_size + 3, 0_u8)
  frame[0] = 0x56_u8
  frame[1] = (0xe0 | (payload_size >> 8)).to_u8
  frame[2] = payload_size.to_u8
  frame
end

def wait_until(timeout = 2.seconds, & : -> Bool)
  deadline = Time.instant + timeout
  until yield
    raise "condition not reached within #{timeout}" if Time.instant >= deadline
    sleep 10.milliseconds
  end
end

def receive(channel : Channel(T), timeout = 2.seconds) : T forall T
  select
  when value = channel.receive
    value
  when timeout(timeout)
    raise "channel did not receive within #{timeout}"
  end
end
