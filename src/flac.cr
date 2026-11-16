require "deque"
require "./stream_join"

# Native FLAC streams (RFC 9639): the `fLaC` marker and metadata blocks, then frames. A frame's
# size isn't in its header, so frames are found by their sync code and checked with the header's
# CRC-8.
module FLAC
  MARKER           = "fLaC".to_slice
  MAX_HEADER_BYTES = 1 << 20
  BLOCK_SIZES      = {0 => 0, 1 => 192, 2 => 576, 3 => 1152, 4 => 2304, 5 => 4608}
  SAMPLE_RATES     = {1 => 88_200, 2 => 176_400, 3 => 192_000, 4 => 8_000, 5 => 16_000, 6 => 22_050, 7 => 24_000,
                      8 => 32_000, 9 => 44_100, 10 => 48_000, 11 => 96_000}

  CRC8_TABLE = Array(UInt8).new(256) do |index|
    crc = index.to_u8
    8.times { crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07_u8) : crc << 1 }
    crc
  end

  CRC16_TABLE = Array(UInt16).new(256) do |index|
    crc = index.to_u16 << 8
    8.times { crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x8005_u16) : crc << 1 }
    crc
  end

  # The STREAMINFO block's audio format.
  record StreamInfo, sample_rate : Int32, channels : Int32, bits_per_sample : Int32, min_block_size : Int32, max_block_size : Int32

  # A frame header: its length in bytes, the samples in the frame, and the sample rate (0 when the
  # frame takes it from STREAMINFO).
  record FrameHeader, size : Int32, block_size : Int32, sample_rate : Int32, channels : Int32

  def self.crc8(bytes : Bytes) : UInt8
    bytes.reduce(0_u8) { |crc, byte| CRC8_TABLE[crc ^ byte] }
  end

  def self.crc16(bytes : Bytes) : UInt16
    bytes.reduce(0_u16) { |crc, byte| (crc << 8) ^ CRC16_TABLE[((crc >> 8) ^ byte) & 0xff] }
  end

  # Parses a STREAMINFO block body (34 bytes).
  def self.stream_info(body : Bytes) : StreamInfo?
    return if body.size < 18
    min_block = IO::ByteFormat::BigEndian.decode(UInt16, body[0, 2]).to_i
    max_block = IO::ByteFormat::BigEndian.decode(UInt16, body[2, 2]).to_i
    rate = (body[10].to_i << 12) | (body[11].to_i << 4) | (body[12].to_i >> 4)
    channels = ((body[12].to_i >> 1) & 0x07) + 1
    bits = (((body[12].to_i & 0x01) << 4) | (body[13].to_i >> 4)) + 1
    StreamInfo.new(rate, channels, bits, min_block, max_block)
  end

  # Parses the frame header at the start of *data*, or nil when there isn't a valid one. *info*
  # rules out headers that contradict the stream's format.
  def self.frame_header(data : Bytes, info : StreamInfo? = nil) : FrameHeader?
    return if data.size < 6
    return unless data[0] == 0xff && (data[1] & 0xfe) == 0xf8
    block_code = (data[2] >> 4).to_i
    rate_code = (data[2] & 0x0f).to_i
    channel_code = (data[3] >> 4).to_i
    size_code = ((data[3] >> 1) & 0x07).to_i
    return if block_code.zero? || rate_code == 15 || channel_code > 10 || (data[3] & 0x01) != 0 || size_code == 3

    offset = 4
    # The frame or sample number, coded like UTF-8 (up to 7 bytes).
    first = data[offset]
    extra = if first < 0x80
              0
            elsif first & 0xe0 == 0xc0
              1
            elsif first & 0xf0 == 0xe0
              2
            elsif first & 0xf8 == 0xf0
              3
            elsif first & 0xfc == 0xf8
              4
            elsif first & 0xfe == 0xfc
              5
            elsif first == 0xfe
              6
            end
    return unless extra
    offset += 1
    return if data.size < offset + extra + 3
    extra.times do
      return unless data[offset] & 0xc0 == 0x80
      offset += 1
    end

    block_size = case block_code
                 when 6
                   offset += 1
                   data[offset - 1].to_i + 1
                 when 7
                   offset += 2
                   IO::ByteFormat::BigEndian.decode(UInt16, data[offset - 2, 2]).to_i + 1
                 when 8..15 then 256 << (block_code - 8)
                 else            BLOCK_SIZES[block_code]
                 end
    sample_rate = case rate_code
                  when  0 then 0
                  when 12 then (offset += 1; data[offset - 1].to_i * 1000)
                  when 13 then (offset += 2; IO::ByteFormat::BigEndian.decode(UInt16, data[offset - 2, 2]).to_i)
                  when 14 then (offset += 2; IO::ByteFormat::BigEndian.decode(UInt16, data[offset - 2, 2]).to_i * 10)
                  else         SAMPLE_RATES[rate_code]
                  end
    return if data.size < offset + 1
    return unless crc8(data[0, offset]) == data[offset]

    channels = channel_code < 8 ? channel_code + 1 : 2
    if info
      return if channels != info.channels
      return if sample_rate.positive? && sample_rate != info.sample_rate
      return if info.max_block_size.positive? && block_size > info.max_block_size
    end
    FrameHeader.new(offset + 1, block_size, sample_rate, channels)
  end

  # Reads the `fLaC` marker and metadata blocks at the start of a stream. Feed it bytes until
  # `complete?`; `rest` is then what followed the headers.
  class HeaderReader
    getter? complete = false
    getter? failed = false
    getter info : StreamInfo?
    getter rest = Bytes.empty
    @data = IO::Memory.new

    def header : Bytes
      @data.to_slice
    end

    def feed(chunk : Bytes) : Nil
      return if @complete || @failed
      start = @data.size
      @data.write(chunk)
      bytes = @data.to_slice
      if bytes.size >= 4 && bytes[0, 4] != MARKER
        @failed = true
        return
      end
      offset = 4
      while offset + 4 <= bytes.size
        length = (bytes[offset + 1].to_i << 16) | (bytes[offset + 2].to_i << 8) | bytes[offset + 3].to_i
        finish = offset + 4 + length
        break if finish > bytes.size
        @info ||= FLAC.stream_info(bytes[offset + 4, length]) if bytes[offset] & 0x7f == 0
        if bytes[offset] & 0x80 != 0
          @complete = true
          @rest = chunk[finish - start..]
          @data = IO::Memory.new(bytes[0, finish])
          return
        end
        offset = finish
      end
      @failed = true if @data.size > MAX_HEADER_BYTES
    end
  end

  # Join points for a native FLAC stream: the start of each frame after the metadata.
  class Join < StreamJoin
    # A frame header can't be checked until this many bytes of it are here.
    HEADER_PROBE = 16

    @reader = HeaderReader.new
    @points = Deque(Int64).new
    @tail = Bytes.empty

    def header : Bytes?
      @reader.header if @reader.complete?
    end

    def join(from : Int64) : Point?
      header = self.header || return
      offset = @points.find(&.>=(from)) || return
      Point.new(offset, header)
    end

    private def scan(data : Bytes) : Nil
      unless @reader.complete?
        return if @reader.failed?
        @reader.feed(data)
        return unless @reader.complete?
        rest = @reader.rest
        # Frames start right after the headers.
        start = @position + data.size - rest.size
        @tail = Bytes.empty
        # The headers may end with the chunk: the first frame then starts the next one.
        return if rest.empty?
        @points << start
        find_frames(rest, start, skip: 1)
        return
      end
      find_frames(data, @position)
    end

    # Records the frames that start in *data* (at stream offset *start*), checking headers that
    # straddle the previous chunk with the bytes kept from it.
    private def find_frames(data : Bytes, start : Int64, skip = 0) : Nil
      bytes = @tail.empty? ? data : Bytes.new(@tail.size + data.size).tap do |joined|
        @tail.copy_to(joined)
        data.copy_to(joined[@tail.size, data.size])
      end
      base = start - @tail.size
      info = @reader.info
      index = skip
      limit = bytes.size - HEADER_PROBE
      while index <= limit
        if bytes[index] == 0xff && FLAC.frame_header(bytes[index, HEADER_PROBE], info)
          @points << base + index
        end
        index += 1
      end
      # The bytes not checked yet: too few to hold a whole frame header.
      keep = (bytes.size - index).clamp(0, HEADER_PROBE)
      @tail = bytes[bytes.size - keep, keep].dup
    end

    private def prune(before : Int64) : Nil
      while (first = @points.first?) && first < before
        @points.shift
      end
    end
  end
end
