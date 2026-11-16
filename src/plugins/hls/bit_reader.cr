module HLS
  # Reads big-endian bit fields, as MPEG-4 audio headers use them.
  class BitReader
    class Error < Exception
    end

    # The bit position from the start.
    getter position = 0

    def initialize(@data : Bytes)
    end

    def read(bits : Int32) : Int32
      raise Error.new("truncated") if @position + bits > @data.size * 8
      value = 0_i64
      bits.times do
        byte = @data[@position >> 3]
        value = (value << 1) | ((byte >> (7 - (@position & 7))) & 1)
        @position += 1
      end
      value.to_i32!
    end

    def skip(bits : Int32) : Nil
      raise Error.new("truncated") if bits.negative? || @position + bits > @data.size * 8
      @position += bits
    end

    def read_bytes(count : Int32) : Bytes
      raise Error.new("truncated") if @position + count * 8 > @data.size * 8
      if (@position & 7).zero?
        bytes = @data[@position >> 3, count].dup
        @position += count * 8
        return bytes
      end
      Bytes.new(count) { read(8).to_u8 }
    end
  end
end
