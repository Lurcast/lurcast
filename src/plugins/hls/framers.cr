require "../../aac"
require "../../flac"
require "../../mp3"
require "../../ogg"
require "./bit_reader"

module HLS
  enum Codec
    MP3
    AAC
    Opus
    FLAC
  end

  # What an fMP4 init segment needs to describe the audio: the codec, sample rate and channels, and
  # its setup data (the AudioSpecificConfig for AAC, the OpusHead for Opus, STREAMINFO for FLAC).
  record TrackConfig, codec : Codec, sample_rate : Int32, channels : Int32, setup : Bytes = Bytes.empty, object_type : Int32 = 2 do
    # The codec as the RFC 6381 `CODECS` attribute names it.
    def codecs : String
      case codec
      in .mp3?  then "mp4a.40.34"
      in .aac?  then "mp4a.40.#{object_type}"
      in .opus? then "opus"
      in .flac? then "fLaC"
      end
    end

    def same?(other : TrackConfig?) : Bool
      !other.nil? && codec == other.codec && sample_rate == other.sample_rate && channels == other.channels && setup == other.setup
    end
  end

  # One frame of audio. *data* is what packed audio carries (a whole MP3 or ADTS frame); fMP4 samples
  # leave out its first *payload_offset* bytes (the ADTS header).
  record Frame, data : Bytes, samples : Int32, sample_rate : Int32, payload_offset : Int32 = 0 do
    def payload : Bytes
      data[payload_offset..]
    end
  end

  # Turns a mount's published bytes into frames. `config` describes the frames yielded last.
  abstract class Framer
    getter config : TrackConfig?
    # Why the stream can't be served over HLS, once that is known.
    getter unsupported : String?

    abstract def codec : Codec
    abstract def write(data : Bytes, & : Frame ->) : Nil
  end

  # MPEG audio frames, as the mount publishes them (whole frames).
  class MP3Framer < Framer
    @free_format_bytes : Int32? = nil

    def codec : Codec
      Codec::MP3
    end

    def write(data : Bytes, & : Frame ->) : Nil
      offset = 0
      while offset < data.size
        frame = MP3.parse_frame(data[offset..], free_format_bytes: @free_format_bytes)
        break unless frame && frame.frame_size.positive? && offset + frame.frame_size <= data.size
        @free_format_bytes = frame.free_format_bytes if frame.free_format_bytes
        unless @config.try { |config| config.sample_rate == frame.sample_rate_hz && config.channels == frame.channels }
          @config = TrackConfig.new(Codec::MP3, frame.sample_rate_hz, frame.channels)
        end
        yield Frame.new(data[offset, frame.frame_size], frame.samples_per_frame, frame.sample_rate_hz)
        offset += frame.frame_size
      end
    end
  end

  # AAC in ADTS frames.
  class ADTSFramer < Framer
    def codec : Codec
      Codec::AAC
    end

    def write(data : Bytes, & : Frame ->) : Nil
      offset = 0
      while offset < data.size
        frame = AAC.parse_header(data[offset..])
        break unless frame && frame.transport.adts? && offset + frame.frame_size <= data.size
        bytes = data[offset, frame.frame_size]
        header_size = (bytes[1] & 0x01).zero? ? 9 : 7
        rate_index = AAC::SAMPLE_RATES.index(frame.sample_rate_hz) || 4
        unless (config = @config) && config.sample_rate == frame.sample_rate_hz && config.channels == frame.channels && config.object_type == frame.profile
          @config = TrackConfig.new(Codec::AAC, frame.sample_rate_hz, frame.channels, AAC.audio_specific_config(frame.profile, rate_index, frame.channels), frame.profile)
        end
        yield Frame.new(bytes, frame.samples_per_frame, frame.sample_rate_hz, header_size)
        offset += frame.frame_size
      end
    end
  end

  # AAC in either transport, chosen by the first frame: a mount's transport is only known once
  # audio arrives.
  class AACFramer < Framer
    # Kept apart, not as one `Framer`, so the yielding `write` calls stay concrete.
    @adts : ADTSFramer?
    @latm : LATMFramer?

    def codec : Codec
      Codec::AAC
    end

    def config : TrackConfig?
      @adts.try(&.config) || @latm.try(&.config)
    end

    def unsupported : String?
      @latm.try(&.unsupported)
    end

    def write(data : Bytes, & : Frame ->) : Nil
      if !@adts && !@latm
        case AAC.parse_header(data).try(&.transport)
        in Nil                  then return
        in AAC::Transport::ADTS then @adts = ADTSFramer.new
        in AAC::Transport::LOAS then @latm = LATMFramer.new
        end
      end
      @adts.try { |adts| adts.write(data) { |frame| yield frame } }
      @latm.try { |latm| latm.write(data) { |frame| yield frame } }
    end
  end

  # AAC in LATM/LOAS (as DAB+ and DVB encoders send it), rewritten as ADTS frames, which HLS packed
  # audio needs. Supports one program and layer, as broadcast encoders use.
  class LATMFramer < Framer
    record StreamConfig, object_type : Int32, core_object_type : Int32, rate_index : Int32, sample_rate : Int32, channels : Int32,
      samples : Int32, frame_length_type : Int32, setup : Bytes

    @stream : StreamConfig?
    @sub_frames = 0

    def codec : Codec
      Codec::AAC
    end

    def write(data : Bytes, & : Frame ->) : Nil
      offset = 0
      while offset + AAC::LOAS_HEADER_SIZE <= data.size
        frame = AAC.parse_header(data[offset..])
        break unless frame && frame.transport.loas? && offset + frame.frame_size <= data.size
        element = data[offset + AAC::LOAS_HEADER_SIZE, frame.frame_size - AAC::LOAS_HEADER_SIZE]
        offset += frame.frame_size
        begin
          audio_mux_element(element) { |payload| emit(payload) { |latm_frame| yield latm_frame } }
        rescue ex : BitReader::Error
          @unsupported ||= "LATM the server can't read (#{ex.message})" if @stream.nil?
        end
      end
    end

    private def emit(payload : Bytes, & : Frame ->) : Nil
      stream = @stream || return
      header = AAC.adts_header(stream.core_object_type, stream.rate_index, stream.channels, payload.size)
      bytes = Bytes.new(header.size + payload.size)
      header.copy_to(bytes)
      payload.copy_to(bytes[header.size, payload.size])
      yield Frame.new(bytes, stream.samples, stream.sample_rate, header.size)
    end

    private def audio_mux_element(element : Bytes, & : Bytes ->) : Nil
      reader = BitReader.new(element)
      stream_mux_config(reader) if reader.read(1).zero?
      stream = @stream || return
      return unless stream.frame_length_type.zero?
      (@sub_frames + 1).times do
        length = 0
        loop do
          value = reader.read(8)
          length += value
          break unless value == 255
        end
        yield reader.read_bytes(length)
      end
    end

    private def stream_mux_config(reader : BitReader) : Nil
      version = reader.read(1)
      version_a = version == 1 ? reader.read(1) : 0
      raise BitReader::Error.new("audioMuxVersionA 1") unless version_a.zero?
      latm_value(reader) if version == 1
      same_time_framing = reader.read(1)
      @sub_frames = reader.read(6)
      programs = reader.read(4)
      layers = reader.read(3)
      raise BitReader::Error.new("more than one program or layer") unless programs.zero? && layers.zero? && same_time_framing == 1
      config = if version == 1
                 length = latm_value(reader)
                 start = reader.position
                 parsed = audio_specific_config(reader)
                 reader.skip(length - (reader.position - start))
                 parsed
               else
                 audio_specific_config(reader)
               end
      frame_length_type = reader.read(3)
      case frame_length_type
      when 0 then reader.read(8) # latmBufferFullness
      when 1 then reader.read(9) # frameLength
      end
      # otherData and CRC
      if reader.read(1) == 1
        if version == 1
          latm_value(reader)
        else
          loop do
            escape = reader.read(1)
            reader.read(8)
            break if escape.zero?
          end
        end
      end
      reader.read(8) if reader.read(1) == 1
      @stream = StreamConfig.new(*config, frame_length_type, AAC.audio_specific_config(config[0], config[2], config[4], sbr_rate_index: config[0] == config[1] ? nil : sbr_index(config)))
      stream = @stream.as(StreamConfig)
      @config = TrackConfig.new(Codec::AAC, stream.sample_rate, stream.channels, stream.setup, stream.object_type) unless @config.try(&.setup.==(stream.setup))
    end

    private def sbr_index(config) : Int32
      AAC::SAMPLE_RATES.index(config[3] * 2) || config[2]
    end

    # Reads an AudioSpecificConfig: {object type, core object type, rate index, rate, channels, samples per frame}.
    private def audio_specific_config(reader : BitReader) : {Int32, Int32, Int32, Int32, Int32, Int32}
      object_type = object_type(reader)
      rate_index, rate = sample_rate(reader)
      channels = reader.read(4)
      core = object_type
      if object_type.in?(5, 29)
        sample_rate(reader)
        core = object_type(reader)
      end
      raise BitReader::Error.new("AAC object type #{core}") unless core.in?(1, 2, 3, 4)
      raise BitReader::Error.new("channel configuration #{channels}") unless 1 <= channels <= 7
      # GASpecificConfig
      samples = reader.read(1).zero? ? 1024 : 960
      reader.skip(14) if reader.read(1) == 1
      reader.read(1)
      channels = 8 if channels == 7
      {object_type, core, rate_index, rate, channels, samples}
    end

    private def object_type(reader : BitReader) : Int32
      type = reader.read(5)
      type == 31 ? 32 + reader.read(6) : type
    end

    private def sample_rate(reader : BitReader) : {Int32, Int32}
      index = reader.read(4)
      return {index, reader.read(24)} if index == 15
      {index, AAC::SAMPLE_RATES[index]? || raise BitReader::Error.new("sample rate index #{index}")}
    end

    private def latm_value(reader : BitReader) : Int32
      bytes = reader.read(2) + 1
      reader.read(bytes * 8)
    end
  end

  # Opus or FLAC from an Ogg stream. Follows the first Opus or FLAC logical stream, and the next one
  # when the source chains a new stream (as some send for each song).
  class OggFramer < Framer
    @sync = Ogg::Sync.new
    @serial : UInt32?
    @kind : Codec?
    @packet = IO::Memory.new
    @packets = 0
    @headers = 1
    @flac_info : FLAC::StreamInfo?
    @pending_config : TrackConfig?

    def codec : Codec
      @kind || Codec::Opus
    end

    def write(data : Bytes, & : Frame ->) : Nil
      @sync.each_page(data) do |_offset, header, body|
        serial = IO::ByteFormat::LittleEndian.decode(UInt32, header[14, 4])
        if (header[5] & 0x02) != 0
          start_stream(serial, body)
        end
        next unless serial == @serial
        @packet.clear if (header[5] & 0x01).zero?
        offset = 0
        header[26].to_i.times do |index|
          length = header[27 + index].to_i
          @packet.write(body[offset, length])
          offset += length
          next if length == 255
          packet(@packet.to_slice) { |frame| yield frame }
          @packet.clear
        end
      end
    end

    private def start_stream(serial : UInt32, body : Bytes) : Nil
      kind = if starts_with?(body, "OpusHead")
               Codec::Opus
             elsif starts_with?(body, "\u007FFLAC")
               Codec::FLAC
             end
      unless kind
        @unsupported ||= "Ogg #{ogg_codec_name(body)} can't be served over HLS" unless @serial
        return
      end
      @serial = serial
      @kind = kind
      @packets = 0
      @headers = 1
      @packet.clear
    end

    private def packet(packet : Bytes, & : Frame ->) : Nil
      @packets += 1
      case @kind
      when Codec::Opus
        if @packets == 1
          return unless packet.size >= 19
          @pending_config = TrackConfig.new(Codec::Opus, 48_000, packet[9].to_i, packet.dup)
        elsif @packets > 2
          samples = HLS.opus_samples(packet)
          take_config
          yield Frame.new(packet.dup, samples, 48_000) if samples.positive?
        end
      when Codec::FLAC
        if @packets == 1
          return unless packet.size >= 51
          count = IO::ByteFormat::BigEndian.decode(UInt16, packet[7, 2]).to_i
          @headers = count.positive? ? count + 1 : Int32::MAX
          info = FLAC.stream_info(packet[17, 34]) || return
          @flac_info = info
          block = Bytes.new(38)
          block[0] = 0x80_u8 # STREAMINFO, the last block
          block[3] = 34_u8
          packet[17, 34].copy_to(block[4, 34])
          @pending_config = TrackConfig.new(Codec::FLAC, info.sample_rate, info.channels, block)
        elsif @packets <= @headers
          @headers = @packets if @headers == Int32::MAX && !packet.empty? && (packet[0] & 0x80) != 0
        else
          info = @flac_info || return
          header = FLAC.frame_header(packet, info) || return
          take_config
          yield Frame.new(packet.dup, header.block_size, header.sample_rate.positive? ? header.sample_rate : info.sample_rate)
        end
      end
    end

    private def take_config : Nil
      if pending = @pending_config
        @config = pending unless pending.same?(@config)
        @pending_config = nil
      end
    end

    private def starts_with?(bytes : Bytes, prefix : String) : Bool
      bytes.size >= prefix.bytesize && bytes[0, prefix.bytesize] == prefix.to_slice
    end

    private def ogg_codec_name(body : Bytes) : String
      return "Vorbis" if body.size >= 7 && body[1, 6] == "vorbis".to_slice
      return "Speex" if starts_with?(body, "Speex   ")
      "with this codec"
    end
  end

  # Native FLAC: the metadata, then frames. A frame ends where the next valid header starts and its
  # CRC-16 checks out.
  class FLACFramer < Framer
    MAX_FRAME = 1 << 20

    @reader = FLAC::HeaderReader.new
    @pending = IO::Memory.new
    # How far `@pending` has been scanned, and the CRC-16 of the bytes before that.
    @scanned = 0
    @crc = 0_u16

    def codec : Codec
      Codec::FLAC
    end

    def write(data : Bytes, & : Frame ->) : Nil
      unless @reader.complete?
        @reader.feed(data)
        @unsupported ||= "a FLAC stream that doesn't start with its metadata" if @reader.failed?
        return unless @reader.complete?
        info = @reader.info || return
        block = Bytes.new(38)
        block[0] = 0x80_u8
        block[3] = 34_u8
        @reader.header[8, 34].copy_to(block[4, 34]) if @reader.header.size >= 42
        @config = TrackConfig.new(Codec::FLAC, info.sample_rate, info.channels, block)
        data = @reader.rest
      end
      info = @reader.info || return
      @pending.write(data)
      bytes = @pending.to_slice
      start = 0
      loop do
        first = FLAC.frame_header(bytes[start..], info)
        unless first
          # Not on a frame: find the next one.
          next_start = (start + 1...bytes.size - 16).find { |index| bytes[index] == 0xff && FLAC.frame_header(bytes[index, 16], info) }
          start = next_start || Math.max(start, bytes.size - 16)
          @scanned = start
          @crc = 0_u16
          break unless next_start
          next
        end
        finish = frame_end(bytes, start, first.size, info)
        break unless finish
        rate = first.sample_rate.positive? ? first.sample_rate : info.sample_rate
        yield Frame.new(bytes[start, finish - start].dup, first.block_size, rate)
        start = finish
        @scanned = start
        @crc = 0_u16
      end
      rest = bytes[Math.max(start, 0)..].dup
      @scanned -= start
      @pending.clear
      @pending.write(rest)
      if @pending.size > MAX_FRAME
        @pending.clear
        @scanned = 0
        @crc = 0_u16
      end
    end

    # The end of the frame starting at *start*: the next valid frame header where the CRC-16 of the
    # bytes so far is zero, or nil until it arrives.
    private def frame_end(bytes : Bytes, start : Int32, header_size : Int32, info : FLAC::StreamInfo) : Int32?
      @scanned = start if @scanned < start
      index = @scanned
      crc = @crc
      while index + 16 <= bytes.size
        if index >= start + header_size && bytes[index] == 0xff && crc.zero? && FLAC.frame_header(bytes[index, 16], info)
          @crc = 0_u16
          return index
        end
        crc = (crc << 8) ^ FLAC::CRC16_TABLE[((crc >> 8) ^ bytes[index]) & 0xff]
        index += 1
      end
      @scanned = index
      @crc = crc
      nil
    end
  end

  # The samples (at 48 kHz) in an Opus packet, from its TOC byte (RFC 6716 section 3.1).
  def self.opus_samples(packet : Bytes) : Int32
    return 0 if packet.empty?
    toc = packet[0]
    config = (toc >> 3).to_i
    per_frame = if config < 12
                  {480, 960, 1920, 2880}[config % 4]
                elsif config < 16
                  config.even? ? 480 : 960
                else
                  {120, 240, 480, 960}[config % 4]
                end
    frames = case toc & 0x03
             when 0    then 1
             when 1, 2 then 2
             else           packet.size > 1 ? (packet[1] & 0x3f).to_i : 0
             end
    per_frame * frames
  end
end
