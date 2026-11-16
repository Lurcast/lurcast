module AAC
  SAMPLE_RATES     = StaticArray[96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
  LOAS_HEADER_SIZE = 3
  SYNC_PROBE_SIZE  = 7

  enum Transport
    ADTS
    LOAS
  end

  record Frame,
    mpeg_version : Int32,
    profile : Int32,
    sample_rate_hz : Int32,
    channels : Int32,
    frame_size : Int32,
    samples_per_frame : Int32,
    transport : Transport = Transport::ADTS do
    def compatible?(other : self) : Bool
      transport == other.transport &&
        (transport.loas? || sample_rate_hz == other.sample_rate_hz && channels == other.channels)
    end
  end

  record LocatedFrame, offset : Int32, frame : Frame

  def self.parse_header(data : Bytes) : Frame?
    parse_adts_header(data) || parse_loas_header(data)
  end

  private def self.parse_adts_header(data : Bytes) : Frame?
    return if data.size < 7
    return unless data[0] == 0xff && (data[1] & 0xf0) == 0xf0 && (data[1] & 0x06).zero?

    sample_rate_hz = SAMPLE_RATES[((data[2] >> 2) & 0x0f).to_i]?
    return unless sample_rate_hz

    header_size = (data[1] & 0x01).zero? ? 9 : 7
    frame_size = ((data[3].to_i & 0x03) << 11) | (data[4].to_i << 3) | (data[5].to_i >> 5)
    return if frame_size < header_size

    Frame.new(
      (data[1] & 0x08).zero? ? 4 : 2,
      ((data[2] >> 6) & 0x03).to_i + 1,
      sample_rate_hz,
      ((data[2].to_i & 0x01) << 2) | (data[3].to_i >> 6),
      frame_size,
      1024 * ((data[6] & 0x03).to_i + 1),
    )
  end

  private def self.parse_loas_header(data : Bytes) : Frame?
    return if data.size < LOAS_HEADER_SIZE
    return unless data[0] == 0x56 && (data[1] & 0xe0) == 0xe0

    payload_size = ((data[1].to_i & 0x1f) << 8) | data[2].to_i
    return unless payload_size.positive?

    Frame.new(4, 0, 0, 0, payload_size + LOAS_HEADER_SIZE, 1024, Transport::LOAS)
  end

  # An AudioSpecificConfig for *object_type* (2 for AAC LC), with explicit SBR signalling
  # (HE-AAC) when *sbr_rate_index* is given.
  def self.audio_specific_config(object_type : Int32, rate_index : Int32, channels : Int32, *, sbr_rate_index : Int32? = nil) : Bytes
    fields = [{object_type, 5}, {rate_index, 4}, {channels, 4}]
    fields.push({sbr_rate_index, 4}, {2, 5}) if sbr_rate_index
    fields << {0, 3} # GASpecificConfig: 1024 samples, no core coder, no extension
    total = fields.sum(&.[1])
    value = fields.reduce(0_u64) { |acc, (field, width)| (acc << width) | (field.to_u64 & ((1_u64 << width) - 1)) }
    size = (total + 7) // 8
    value <<= size * 8 - total
    Bytes.new(size) { |index| (value >> ((size - 1 - index) * 8)).to_u8! }
  end

  # A 7-byte ADTS header (no CRC) for a raw AAC frame of *payload_size* bytes.
  def self.adts_header(object_type : Int32, rate_index : Int32, channels : Int32, payload_size : Int32) : Bytes
    length = payload_size + 7
    header = Bytes.new(7)
    header[0] = 0xff_u8
    header[1] = 0xf1_u8
    header[2] = ((((object_type - 1) & 0x03) << 6) | ((rate_index & 0x0f) << 2) | ((channels >> 2) & 0x01)).to_u8
    header[3] = (((channels & 0x03) << 6) | ((length >> 11) & 0x03)).to_u8
    header[4] = ((length >> 3) & 0xff).to_u8
    header[5] = (((length & 0x07) << 5) | 0x1f).to_u8
    header[6] = 0xfc_u8
    header
  end

  def self.find_frame(data : Bytes, require_complete = false) : LocatedFrame?
    return if data.size < LOAS_HEADER_SIZE

    fallback = nil.as(LocatedFrame?)
    (0..data.size - LOAS_HEADER_SIZE).each do |offset|
      frame = parse_header(data[offset..])
      next unless frame

      frame_end = offset + frame.frame_size
      next if require_complete && frame_end > data.size

      located = LocatedFrame.new(offset, frame)
      if frame_end + LOAS_HEADER_SIZE <= data.size
        if next_frame = parse_header(data[frame_end..])
          return located if frame.compatible?(next_frame)
        end
      elsif !require_complete || frame_end <= data.size
        fallback ||= located
      end
    end
    fallback
  end
end
