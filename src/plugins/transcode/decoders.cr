require "../../aac"
require "../../mp3"
require "../../ogg"
require "./native"

class Lurcast::Plugins::Transcode < Lurcast::Plugin
  # The input can't be transcoded: an unsupported format or codec, or data a decoder rejects.
  class UnsupportedInput < Exception
  end

  # Bytes waiting to be decoded: appended at the end, consumed from the front.
  class ByteQueue
    @data = Bytes.new(16_384)
    @start = 0
    @finish = 0

    def initialize(@limit : Int32)
    end

    def bytes : Bytes
      @data[@start, @finish - @start]
    end

    def size : Int32
      @finish - @start
    end

    def append(chunk : Bytes) : Nil
      raise UnsupportedInput.new("the decoder found no audio in #{size} bytes") if size + chunk.size > @limit
      if @finish + chunk.size > @data.size
        pending = bytes
        if pending.size + chunk.size > @data.size
          grown = Bytes.new(Math.pw2ceil(pending.size + chunk.size))
          pending.copy_to(grown)
          @data = grown
        else
          pending.move_to(@data)
        end
        @start = 0
        @finish = pending.size
      end
      chunk.copy_to(@data[@finish, chunk.size])
      @finish += chunk.size
    end

    def consume(count : Int32) : Nil
      @start += count.clamp(0, size)
      @start = @finish = 0 if @start == @finish
    end

    def clear : Nil
      @start = @finish = 0
    end
  end

  # Turns a stream's bytes into interleaved float samples. `decode` yields each decoded block with its
  # channel count and sample rate; the samples are only valid until the block returns.
  abstract class Decoder
    abstract def decode(data : Bytes, & : Slice(Float32), Int32, Int32 ->) : Nil

    def close : Nil
    end

    FORMATS = {"mp3", "ogg"}

    def self.supported?(format : String) : Bool
      FORMATS.includes?(format) || format == "aac" && FDK.available?
    end

    # Why a mount's format can't be transcoded.
    def self.unsupported_reason(format : String) : String
      format == "aac" ? "AAC sources need the Fraunhofer FDK AAC library: #{FDK.error}" : "#{format} streams can't be transcoded"
    end

    # The decoder for a mount's format ("mp3", "ogg", ...), or nil when it can't be transcoded.
    def self.for(format : String) : Decoder?
      case format
      when "mp3" then MP3Decoder.new
      when "aac" then FDK.library.try { |fdk| AACDecoder.new(fdk) }
      when "ogg" then OggDecoder.new
      end
    end
  end

  # MPEG audio (layers I to III) with minimp3.
  class MP3Decoder < Decoder
    # minimp3 skips a frame it only has part of, so a frame is decoded once it and the next frame's
    # header are buffered. When the frame size isn't known (free format, or no header at the start),
    # decoding waits for this much, which covers two free-format frames (at most 2304 bytes each).
    WINDOW = 4800

    @state = Pointer(LibLurcastExt::MP3Decoder).malloc(1)
    @pcm = Slice(Float32).new(LibLurcastExt::MP3_MAX_SAMPLES_PER_FRAME)
    @pending = ByteQueue.new(1 << 20)

    def initialize
      LibLurcastExt.mp3dec_init(@state)
    end

    def decode(data : Bytes, & : Slice(Float32), Int32, Int32 ->) : Nil
      @pending.append(data)
      loop do
        input = @pending.bytes
        break if input.size < 4
        frame = MP3.parse_header(input[0, 4])
        break if input.size < (frame ? frame.frame_size + 4 : WINDOW)
        info = LibLurcastExt::MP3FrameInfo.new
        samples = LibLurcastExt.mp3dec_decode_frame(@state, input.to_unsafe, input.size, @pcm.to_unsafe, pointerof(info))
        break if info.frame_bytes <= 0
        @pending.consume(info.frame_bytes)
        yield @pcm[0, samples * info.channels], info.channels, info.hz if samples.positive? && info.channels.positive?
      end
    end
  end

  # Ogg with Vorbis or Opus. A new beginning-of-stream page for a supported codec (a chained stream,
  # as sources send for each new song) starts a new decoder; other logical streams are ignored.
  class OggDecoder < Decoder
    @sync = Ogg::Sync.new
    @serial : UInt32?
    @codec : OggCodec?
    @unknown : String?

    def decode(data : Bytes, & : Slice(Float32), Int32, Int32 ->) : Nil
      @sync.each_page(data) do |_offset, header, body|
        serial = IO::ByteFormat::LittleEndian.decode(UInt32, header[14, 4])
        if (header[5] & 0x02) != 0
          case kind = OggDecoder.codec_name(body)
          when "Vorbis", "Opus"
            @codec.try(&.close)
            @codec = kind == "Vorbis" ? VorbisCodec.new : OpusCodec.new
            @serial = serial
          when "Skeleton"
          else
            @unknown ||= kind
          end
        end

        codec = @codec
        if codec && serial == @serial
          codec.page(header, body) { |pcm, channels, rate| yield pcm, channels, rate }
        elsif codec.nil? && (header[5] & 0x02) == 0
          raise UnsupportedInput.new("Ogg #{@unknown || "with an unknown codec"}")
        end
      end
    end

    def close : Nil
      @codec.try(&.close)
      @codec = nil
      @sync.close
    end

    def self.codec_name(packet : Bytes) : String
      return "Vorbis" if packet.size >= 7 && packet[0] == 1 && packet[1, 6] == "vorbis".to_slice
      return "Opus" if starts_with?(packet, "OpusHead")
      return "Skeleton" if starts_with?(packet, "fishead\0")
      return "FLAC" if starts_with?(packet, "\x7FFLAC")
      return "Speex" if starts_with?(packet, "Speex   ")
      return "Theora" if packet.size >= 7 && packet[0] == 0x80 && packet[1, 6] == "theora".to_slice
      "with an unknown codec"
    end

    def self.starts_with?(bytes : Bytes, prefix : String) : Bool
      bytes.size >= prefix.bytesize && bytes[0, prefix.bytesize] == prefix.to_slice
    end
  end

  # Decodes the pages of one Ogg logical stream.
  abstract class OggCodec
    abstract def page(header : Bytes, body : Bytes, & : Slice(Float32), Int32, Int32 ->) : Nil
    abstract def close : Nil
  end

  # Vorbis with stb_vorbis's push API, which reads whole Ogg pages and finds packets itself.
  class VorbisCodec < OggCodec
    @handle : LibLurcastExt::Vorbis?
    @pending = ByteQueue.new(1 << 20)
    @pcm = Slice(Float32).new(0)
    @rate = 0

    def page(header : Bytes, body : Bytes, & : Slice(Float32), Int32, Int32 ->) : Nil
      @pending.append(header)
      @pending.append(body)
      handle = @handle || open || return
      loop do
        input = @pending.bytes
        break if input.empty?
        channels = 0
        samples = 0
        output = Pointer(Pointer(Float32)).null
        used = LibLurcastExt.stb_vorbis_decode_frame_pushdata(handle, input.to_unsafe, input.size, pointerof(channels), pointerof(output), pointerof(samples))
        break if used.zero?
        @pending.consume(used)
        next unless samples.positive? && channels.positive?
        yield interleave(output, channels, samples), channels, @rate
      end
    end

    def close : Nil
      @handle.try { |handle| LibLurcastExt.stb_vorbis_close(handle) }
      @handle = nil
    end

    def finalize
      close
    end

    private def open : LibLurcastExt::Vorbis?
      input = @pending.bytes
      used = 0
      error = 0
      handle = LibLurcastExt.stb_vorbis_open_pushdata(input.to_unsafe, input.size, pointerof(used), pointerof(error), nil)
      if handle.null?
        return if error == LibLurcastExt::VORBIS_NEED_MORE_DATA
        raise UnsupportedInput.new("Vorbis headers the decoder rejects (stb_vorbis error #{error})")
      end
      @pending.consume(used)
      @rate = LibLurcastExt.stb_vorbis_get_info(handle).sample_rate.to_i
      @handle = handle
    end

    private def interleave(output : Pointer(Pointer(Float32)), channels : Int32, samples : Int32) : Slice(Float32)
      @pcm = Slice(Float32).new(samples * channels) if @pcm.size < samples * channels
      channels.times do |channel|
        plane = output[channel]
        samples.times { |index| @pcm[index * channels + channel] = plane[index] }
      end
      @pcm[0, samples * channels]
    end
  end

  # Opus with libopus. Only channel mapping family 0 (mono or stereo) is supported.
  class OpusCodec < OggCodec
    MAX_FRAME = 5760

    @decoder : LibOpus::Decoder?
    @packet = IO::Memory.new
    @header_packets = 0
    @channels = 2
    @skip = 0
    @gain = 1.0_f32
    @pcm = Slice(Float32).new(MAX_FRAME * 2)

    def page(header : Bytes, body : Bytes, & : Slice(Float32), Int32, Int32 ->) : Nil
      @packet.clear if (header[5] & 0x01) == 0
      segments = header[26].to_i
      offset = 0
      segments.times do |index|
        length = header[27 + index].to_i
        @packet.write(body[offset, length])
        offset += length
        next if length == 255
        packet(@packet.to_slice) { |pcm, channels, rate| yield pcm, channels, rate }
        @packet.clear
      end
    end

    def close : Nil
      @decoder.try { |decoder| LibOpus.decoder_destroy(decoder) }
      @decoder = nil
    end

    def finalize
      close
    end

    private def packet(data : Bytes, & : Slice(Float32), Int32, Int32 ->) : Nil
      @header_packets += 1
      case @header_packets
      when 1 then open(data)
      when 2 then nil # OpusTags
      else
        decoder = @decoder || return
        samples = LibOpus.decode_float(decoder, data.to_unsafe, data.size, @pcm.to_unsafe, MAX_FRAME, 0)
        return unless samples.positive?
        skipped = Math.min(@skip, samples)
        @skip -= skipped
        pcm = @pcm[skipped * @channels, (samples - skipped) * @channels]
        pcm.map! { |sample| sample * @gain } unless @gain == 1.0_f32
        yield pcm, @channels, 48_000 unless pcm.empty?
      end
    end

    private def open(head : Bytes) : Nil
      raise UnsupportedInput.new("an Opus stream without an OpusHead") unless head.size >= 19 && OggDecoder.starts_with?(head, "OpusHead")
      channels = head[9].to_i
      family = head[18]
      unless family == 0 && channels.in?(1, 2)
        raise UnsupportedInput.new("multichannel Opus (#{channels} channels, mapping family #{family})")
      end
      error = 0
      decoder = LibOpus.decoder_create(48_000, channels, pointerof(error))
      raise UnsupportedInput.new("Opus the decoder rejects: #{String.new(LibOpus.strerror(error))}") if error != LibOpus::OK
      @decoder = decoder
      @channels = channels
      @skip = IO::ByteFormat::LittleEndian.decode(UInt16, head[10, 2]).to_i
      gain_q8 = IO::ByteFormat::LittleEndian.decode(Int16, head[16, 2])
      @gain = (10.0 ** (gain_q8 / (20.0 * 256))).to_f32
    end
  end
end
