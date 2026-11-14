module Ultravox
  SYNC        = 0x5a_u8
  MAX_PAYLOAD =  16_377

  record Message, type : UInt16, payload : Bytes

  def self.read(io : IO, sync_read = false) : Message
    sync = sync_read ? SYNC : io.read_byte
    raise ArgumentError.new("invalid Ultravox sync") unless sync == SYNC

    header = uninitialized UInt8[5]
    bytes = header.to_slice
    io.read_fully(bytes)
    type = IO::ByteFormat::BigEndian.decode(UInt16, bytes[1, 2])
    length = IO::ByteFormat::BigEndian.decode(UInt16, bytes[3, 2]).to_i
    raise ArgumentError.new("Ultravox payload is too large") if length > MAX_PAYLOAD

    payload = Bytes.new(length)
    io.read_fully(payload)
    raise ArgumentError.new("invalid Ultravox trailer") unless io.read_byte == 0
    Message.new(type, payload)
  end

  def self.write(io : IO, type : UInt16, payload : String)
    write(io, type, payload.to_slice)
  end

  def self.write(io : IO, type : UInt16, payload : Bytes)
    raise ArgumentError.new("Ultravox payload is too large") if payload.size > MAX_PAYLOAD

    header = StaticArray(UInt8, 6).new(0_u8)
    bytes = header.to_slice
    bytes[0] = SYNC
    IO::ByteFormat::BigEndian.encode(type, bytes[2, 2])
    IO::ByteFormat::BigEndian.encode(payload.size.to_u16, bytes[4, 2])
    io.write(bytes)
    io.write(payload)
    io.write_byte(0_u8)
    io.flush
  end

  def self.text(payload : Bytes) : String
    String.new(payload, truncate_at_null: true)
  end

  def self.data_type?(type : UInt16) : Bool
    type.in?(0x7000_u16, 0x8001_u16, 0x8002_u16, 0x8003_u16)
  end

  def self.data_type_matches?(type : UInt16, content_type : String) : Bool
    case type
    when 0x7000 then content_type == "audio/mpeg"
    when 0x8001 then content_type == "audio/ogg"
    when 0x8002 then content_type == "audio/speex"
    when 0x8003 then content_type.in?("audio/aac", "audio/aacp")
    else             false
    end
  end

  def self.decrypt(hex : String, cipher_key : String) : String
    encrypted = hex.hexbytes
    raise ArgumentError.new("invalid encrypted Ultravox credential") unless encrypted.size.positive? && encrypted.size % 8 == 0

    key = StaticArray(UInt8, 16).new(0_u8)
    key_bytes = key.to_slice
    cipher_key.to_slice[0, Math.min(cipher_key.bytesize, key.size)].copy_to(key_bytes)
    words = StaticArray[
      IO::ByteFormat::BigEndian.decode(UInt32, key_bytes[0, 4]),
      IO::ByteFormat::BigEndian.decode(UInt32, key_bytes[4, 4]),
      IO::ByteFormat::BigEndian.decode(UInt32, key_bytes[8, 4]),
      IO::ByteFormat::BigEndian.decode(UInt32, key_bytes[12, 4]),
    ]
    decoded = Bytes.new(encrypted.size)

    (0...encrypted.size).step(by: 8) do |offset|
      block = encrypted[offset, 8]
      v0 = IO::ByteFormat::BigEndian.decode(UInt32, block[0, 4])
      v1 = IO::ByteFormat::BigEndian.decode(UInt32, block[4, 4])
      sum = 0xc6ef3720_u32
      32.times do
        v1 &-= ((((v0 << 4) ^ (v0 >> 5)) &+ v0) ^ (sum &+ words[((sum >> 11) & 3).to_i]))
        sum &-= 0x9e3779b9_u32
        v0 &-= ((((v1 << 4) ^ (v1 >> 5)) &+ v1) ^ (sum &+ words[(sum & 3).to_i]))
      end
      IO::ByteFormat::BigEndian.encode(v0, decoded[offset, 4])
      IO::ByteFormat::BigEndian.encode(v1, decoded[offset + 4, 4])
    end

    String.new(decoded, truncate_at_null: true)
  rescue ArgumentError
    raise ArgumentError.new("invalid encrypted Ultravox credential")
  end
end
