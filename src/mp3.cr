module MP3
  private MAX_FREE_FORMAT_FRAME_SIZE = 2304
  private FREE_FORMAT_PROBE_SIZE     = (MAX_FREE_FORMAT_FRAME_SIZE + 4) * 2

  record Frame,
    version : String,
    layer : Int32,
    bitrate_kbps : Int32,
    sample_rate_hz : Int32,
    channels : Int32,
    frame_size : Int32,
    samples_per_frame : Int32,
    free_format_bytes : Int32? = nil do
    def compatible?(other : self) : Bool
      version == other.version && layer == other.layer && sample_rate_hz == other.sample_rate_hz
    end
  end

  record LocatedFrame, offset : Int32, frame : Frame

  private record Header,
    version : String,
    layer : Int32,
    bitrate_index : Int32,
    sample_rate_hz : Int32,
    channels : Int32,
    padding_bytes : Int32,
    samples_per_frame : Int32 do
    def compatible?(other : self) : Bool
      version == other.version && layer == other.layer && sample_rate_hz == other.sample_rate_hz
    end
  end

  def self.parse_header(header : Bytes) : Frame?
    return unless decoded = decode_header(header)
    return if decoded.bitrate_index.zero?

    build_frame(decoded, bitrate(decoded.version, decoded.layer, decoded.bitrate_index))
  end

  def self.parse_frame(data : Bytes, *, free_format_bytes : Int32? = nil) : Frame?
    return unless header = decode_header(data)
    unless header.bitrate_index.zero?
      return build_frame(header, bitrate(header.version, header.layer, header.bitrate_index))
    end

    if free_format_bytes
      return build_free_format_frame(header, free_format_bytes)
    end

    if frame = infer_free_format_frame(data, header)
      return frame
    end
    build_frame(header, 0, 0) if data.size < FREE_FORMAT_PROBE_SIZE
  end

  def self.find_frame(data : Bytes, require_complete = false, *, free_format_bytes : Int32? = nil) : LocatedFrame?
    return if data.size < 4

    fallback = nil.as(LocatedFrame?)
    (0..data.size - 4).each do |offset|
      frame = parse_frame(data[offset..], free_format_bytes: free_format_bytes)
      next unless frame && frame.frame_size.positive?
      free_format_bytes = frame.free_format_bytes

      located = LocatedFrame.new(offset, frame)
      frame_end = offset + frame.frame_size
      next if require_complete && frame_end > data.size

      if frame_end + 4 <= data.size
        if next_frame = parse_frame(data[frame_end..], free_format_bytes: free_format_bytes)
          return located if frame.compatible?(next_frame)
        end
      elsif !require_complete || frame_end <= data.size
        fallback ||= located
      end
    end
    fallback
  end

  private def self.decode_header(data : Bytes) : Header?
    return if data.size < 4
    bits = IO::ByteFormat::BigEndian.decode(UInt32, data[0, 4])
    return unless (bits & 0xffe00000) == 0xffe00000

    version_bits = ((bits >> 19) & 0x03).to_i
    layer_bits = ((bits >> 17) & 0x03).to_i
    bitrate_index = ((bits >> 12) & 0x0f).to_i
    sample_rate_index = ((bits >> 10) & 0x03).to_i
    padding = ((bits >> 9) & 0x01).to_i

    version = case version_bits
              when 0 then "2.5"
              when 2 then "2"
              when 3 then "1"
              else        return
              end
    layer = case layer_bits
            when 1 then 3
            when 2 then 2
            when 3 then 1
            else        return
            end
    return if bitrate_index == 15 || sample_rate_index == 3

    sample_rate_hz = sample_rate(version, sample_rate_index)
    samples_per_frame = samples_per_frame(version, layer)
    channels = ((bits >> 6) & 0x03) == 3 ? 1 : 2
    padding_bytes = padding * (layer == 1 ? 4 : 1)

    Header.new(version, layer, bitrate_index, sample_rate_hz, channels, padding_bytes, samples_per_frame)
  end

  private def self.infer_free_format_frame(data : Bytes, header : Header) : Frame?
    maximum = Math.min(MAX_FREE_FORMAT_FRAME_SIZE - 1, data.size - 4)
    return if maximum < 4

    # ponytail: bounded initial scan; keep incremental search state only if byte-sized source writes make this measurable.
    (4..maximum).each do |frame_size|
      next_header = decode_header(data[frame_size..])
      next unless next_header && next_header.bitrate_index.zero? && header.compatible?(next_header)

      free_format_bytes = frame_size - header.padding_bytes
      next unless free_format_bytes.positive?
      next_frame_size = free_format_bytes + next_header.padding_bytes
      third_offset = frame_size + next_frame_size
      next if third_offset + 4 > data.size

      third_header = decode_header(data[third_offset..])
      next unless third_header && third_header.bitrate_index.zero? && header.compatible?(third_header)

      return build_free_format_frame(header, free_format_bytes)
    end
    nil
  end

  private def self.build_free_format_frame(header : Header, free_format_bytes : Int32) : Frame
    bitrate_kbps = estimate_free_format_bitrate(header, free_format_bytes)
    build_frame(header, bitrate_kbps, free_format_bytes)
  end

  private def self.build_frame(header : Header, bitrate_kbps : Int32, free_format_bytes : Int32? = nil) : Frame
    frame_size = if free_format_bytes
                   free_format_bytes + header.padding_bytes
                 elsif header.layer == 1
                   (12 * bitrate_kbps * 1000 // header.sample_rate_hz) * 4 + header.padding_bytes
                 else
                   header.samples_per_frame * bitrate_kbps * 1000 // (header.sample_rate_hz * 8) + header.padding_bytes
                 end
    Frame.new(
      header.version,
      header.layer,
      bitrate_kbps,
      header.sample_rate_hz,
      header.channels,
      frame_size,
      header.samples_per_frame,
      free_format_bytes
    )
  end

  private def self.estimate_free_format_bitrate(header : Header, free_format_bytes : Int32) : Int32
    numerator, denominator = if header.layer == 1
                               {(free_format_bytes // 4) * header.sample_rate_hz, 12_000}
                             else
                               {free_format_bytes * header.sample_rate_hz * 8, header.samples_per_frame * 1000}
                             end
    (numerator + denominator // 2) // denominator
  end

  private def self.bitrate(version : String, layer : Int32, index : Int32) : Int32
    table = if version == "1"
              case layer
              when 1 then {0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448}
              when 2 then {0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384}
              else        {0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320}
              end
            elsif layer == 1
              {0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256}
            else
              {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160}
            end
    table[index]
  end

  private def self.sample_rate(version : String, index : Int32) : Int32
    rate = {44_100, 48_000, 32_000}[index]
    return rate if version == "1"
    return rate // 2 if version == "2"
    rate // 4
  end

  private def self.samples_per_frame(version : String, layer : Int32) : Int32
    return 384 if layer == 1
    return 1152 if layer == 2 || version == "1"
    576
  end
end
