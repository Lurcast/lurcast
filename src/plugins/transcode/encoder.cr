require "./native"

class Lurcast::Plugins::Transcode < Lurcast::Plugin
  # Mixes decoded audio to the configured channel count, resamples it to 48 kHz and encodes 20 ms
  # Opus packets. One encoder lives as long as its transcoder, so the output stays one continuous
  # Opus stream when the input's format, sample rate or channel count changes.
  class OpusEncoder
    RATE       = 48_000
    FRAME_SIZE =    960 # 20 ms
    MAX_PACKET =   4000
    QUALITY    =      5 # SPEEX_RESAMPLER_QUALITY_DESKTOP

    getter channels : Int32
    getter pre_skip : Int32

    @encoder : LibOpus::Encoder
    @resampler : LibLurcastExt::Resampler?
    @resampler_rate = 0
    @frame : Slice(Float32)
    @filled = 0
    @mixed = Slice(Float32).new(0)
    @resampled = Slice(Float32).new(0)
    @packet = Bytes.new(MAX_PACKET)
    @closed = false

    def initialize(bitrate_kbps : Int32, @channels : Int32)
      error = 0
      @encoder = LibOpus.encoder_create(RATE, @channels, LibOpus::APPLICATION_AUDIO, pointerof(error))
      raise ArgumentError.new("Opus encoder: #{String.new(LibOpus.strerror(error))}") unless error == LibOpus::OK
      LibOpus.encoder_ctl(@encoder, LibOpus::SET_BITRATE_REQUEST, bitrate_kbps * 1000)
      lookahead = 0
      LibOpus.encoder_ctl(@encoder, LibOpus::GET_LOOKAHEAD, pointerof(lookahead))
      @pre_skip = lookahead
      @frame = Slice(Float32).new(FRAME_SIZE * @channels)
    end

    def bitrate : Int32
      value = 0
      LibOpus.encoder_ctl(@encoder, LibOpus::GET_BITRATE_REQUEST, pointerof(value))
      value
    end

    # Encodes *pcm* (interleaved, *channels* channels at *rate* Hz) and yields each finished packet.
    # Leftover samples wait for the next call. Packets are only valid until the block returns.
    def encode(pcm : Slice(Float32), channels : Int32, rate : Int32, & : Bytes ->) : Nil
      raise IO::Error.new("Opus encoder is closed") if @closed
      return if pcm.empty? || channels <= 0 || rate <= 0
      mixed = mix(pcm, channels)
      mixed = resample(mixed, rate) unless rate == RATE
      push(mixed) { |packet| yield packet }
    end

    def close : Nil
      return if @closed
      @closed = true
      LibOpus.encoder_destroy(@encoder)
      @resampler.try { |resampler| LibLurcastExt.resampler_destroy(resampler) }
      @resampler = nil
    end

    def finalize
      close
    end

    private def push(samples : Slice(Float32), & : Bytes ->) : Nil
      offset = 0
      while offset < samples.size
        wanted = @frame.size - @filled
        count = Math.min(wanted, samples.size - offset)
        samples[offset, count].copy_to(@frame[@filled, count])
        @filled += count
        offset += count
        next unless @filled == @frame.size
        @filled = 0
        size = LibOpus.encode_float(@encoder, @frame.to_unsafe, FRAME_SIZE, @packet.to_unsafe, MAX_PACKET)
        raise IO::Error.new("Opus encoding failed: #{String.new(LibOpus.strerror(size))}") if size < 0
        yield @packet[0, size]
      end
    end

    private def mix(pcm : Slice(Float32), channels : Int32) : Slice(Float32)
      return pcm if channels == @channels
      frames = pcm.size // channels
      @mixed = Slice(Float32).new(frames * @channels) if @mixed.size < frames * @channels
      mixed = @mixed[0, frames * @channels]
      if channels == 1
        frames.times { |index| mixed[index * 2] = mixed[index * 2 + 1] = pcm[index] }
        return mixed
      end
      gains = OpusEncoder.stereo_gains(channels)
      frames.times do |index|
        left = right = 0.0_f32
        channels.times do |channel|
          sample = pcm[index * channels + channel]
          gain = gains[channel]
          left += sample * gain[0]
          right += sample * gain[1]
        end
        if @channels == 1
          mixed[index] = (left + right) * 0.5_f32
        else
          mixed[index * 2] = left
          mixed[index * 2 + 1] = right
        end
      end
      mixed
    end

    # How much each input channel adds to the left and right output, for the Vorbis channel orders
    # (Opus and FLAC use the same). Each side's gains add up to 1, so a downmix can't clip.
    def self.stereo_gains(channels : Int32) : Array(Tuple(Float32, Float32))
      c = 0.7071_f32
      gains = case channels
              when 2 then [{1f32, 0f32}, {0f32, 1f32}]
              when 3 then [{1f32, 0f32}, {c, c}, {0f32, 1f32}]
              when 4 then [{1f32, 0f32}, {0f32, 1f32}, {c, 0f32}, {0f32, c}]
              when 5 then [{1f32, 0f32}, {c, c}, {0f32, 1f32}, {c, 0f32}, {0f32, c}]
              when 6 then [{1f32, 0f32}, {c, c}, {0f32, 1f32}, {c, 0f32}, {0f32, c}, {0f32, 0f32}]
              when 7 then [{1f32, 0f32}, {c, c}, {0f32, 1f32}, {c, 0f32}, {0f32, c}, {c / 2, c / 2}, {0f32, 0f32}]
              when 8 then [{1f32, 0f32}, {c, c}, {0f32, 1f32}, {c, 0f32}, {0f32, c}, {c, 0f32}, {0f32, c}, {0f32, 0f32}]
              else        Array.new(channels) { |index| index == 0 ? {1f32, 0f32} : (index == 1 ? {0f32, 1f32} : {0f32, 0f32}) }
              end
      left = gains.sum(&.[0])
      right = gains.sum(&.[1])
      gains.map { |(l, r)| {l / left, r / right} }
    end

    private def resample(pcm : Slice(Float32), rate : Int32) : Slice(Float32)
      resampler = resampler_for(rate)
      input_frames = pcm.size // @channels
      capacity = (input_frames.to_i64 * RATE // rate + 64).to_i
      @resampled = Slice(Float32).new(capacity * @channels) if @resampled.size < capacity * @channels
      consumed = 0
      produced = 0
      while consumed < input_frames
        in_length = (input_frames - consumed).to_u32
        out_length = (capacity - produced).to_u32
        break if out_length.zero?
        LibLurcastExt.resampler_process_interleaved_float(resampler, pcm.to_unsafe + consumed * @channels, pointerof(in_length),
          @resampled.to_unsafe + produced * @channels, pointerof(out_length))
        break if in_length.zero? && out_length.zero?
        consumed += in_length.to_i
        produced += out_length.to_i
      end
      @resampled[0, produced * @channels]
    end

    private def resampler_for(rate : Int32) : LibLurcastExt::Resampler
      if (resampler = @resampler) && @resampler_rate == rate
        return resampler
      end
      @resampler.try { |old| LibLurcastExt.resampler_destroy(old) }
      error = 0
      resampler = LibLurcastExt.resampler_init(@channels.to_u32, rate.to_u32, RATE.to_u32, QUALITY, pointerof(error))
      raise UnsupportedInput.new("audio at #{rate} Hz the resampler rejects") if resampler.null? || error != 0
      @resampler = resampler
      @resampler_rate = rate
      resampler
    end
  end

  # Writes Opus packets as an Ogg Opus stream (RFC 7845): an OpusHead page, an OpusTags page, then
  # audio pages of up to `PACKETS_PER_PAGE` packets with their granule positions.
  class OggOpusWriter
    PACKETS_PER_PAGE = 10 # 200 ms per page
    CRC_TABLE        = Array(UInt32).new(256) do |index|
      crc = index.to_u32 << 24
      8.times { crc = (crc & 0x80000000_u32) != 0 ? (crc << 1) ^ 0x04c11db7_u32 : crc << 1 }
      crc
    end

    getter granule = 0_i64
    getter serial : UInt32
    @sequence = 0_u32
    @segments = [] of UInt8
    @body = IO::Memory.new
    @packets = 0

    def initialize(@io : IO, channels : Int32, pre_skip : Int32, @serial = Random.rand(UInt32::MAX))
      head = IO::Memory.new
      head << "OpusHead"
      head.write_byte(1_u8)
      head.write_byte(channels.to_u8)
      head.write_bytes(pre_skip.to_u16, IO::ByteFormat::LittleEndian)
      head.write_bytes(OpusEncoder::RATE.to_u32, IO::ByteFormat::LittleEndian)
      head.write_bytes(0_i16, IO::ByteFormat::LittleEndian)
      head.write_byte(0_u8)
      write_page(head.to_slice, 0x02_u8, 0_i64)

      vendor = "Lurcast (#{String.new(LibOpus.get_version_string)})"
      comment = "ENCODER=Lurcast"
      tags = IO::Memory.new
      tags << "OpusTags"
      tags.write_bytes(vendor.bytesize.to_u32, IO::ByteFormat::LittleEndian)
      tags << vendor
      tags.write_bytes(1_u32, IO::ByteFormat::LittleEndian)
      tags.write_bytes(comment.bytesize.to_u32, IO::ByteFormat::LittleEndian)
      tags << comment
      write_page(tags.to_slice, 0_u8, 0_i64)
      @io.flush
    end

    # Adds one 20 ms packet; full pages are written out.
    def write(packet : Bytes) : Nil
      flush if @segments.size + packet.size // 255 + 1 > 255
      (packet.size // 255).times { @segments << 255_u8 }
      @segments << (packet.size % 255).to_u8
      @body.write(packet)
      @granule += OpusEncoder::FRAME_SIZE
      @packets += 1
      flush if @packets >= PACKETS_PER_PAGE
    end

    # Writes out the packets added since the last page.
    def flush : Nil
      return if @packets.zero?
      write_segments(@body.to_slice, @segments, 0_u8, @granule)
      @body.clear
      @segments.clear
      @packets = 0
      @io.flush
    end

    private def write_page(packet : Bytes, header_type : UInt8, granule : Int64) : Nil
      segments = Array(UInt8).new(packet.size // 255 + 1) { |index| index < packet.size // 255 ? 255_u8 : (packet.size % 255).to_u8 }
      write_segments(packet, segments, header_type, granule)
    end

    private def write_segments(body : Bytes, segments : Array(UInt8), header_type : UInt8, granule : Int64) : Nil
      page = Bytes.new(27 + segments.size + body.size)
      "OggS".to_slice.copy_to(page)
      page[4] = 0_u8
      page[5] = header_type
      IO::ByteFormat::LittleEndian.encode(granule, page[6, 8])
      IO::ByteFormat::LittleEndian.encode(@serial, page[14, 4])
      IO::ByteFormat::LittleEndian.encode(@sequence, page[18, 4])
      page[26] = segments.size.to_u8
      segments.each_with_index { |segment, index| page[27 + index] = segment }
      body.copy_to(page[27 + segments.size, body.size])
      IO::ByteFormat::LittleEndian.encode(OggOpusWriter.crc(page), page[22, 4])
      @sequence += 1
      @io.write(page)
    end

    def self.crc(page : Bytes) : UInt32
      page.reduce(0_u32) { |crc, byte| (crc << 8) ^ CRC_TABLE[((crc >> 24) ^ byte) & 0xff] }
    end
  end
end
