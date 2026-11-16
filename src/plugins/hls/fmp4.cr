require "./framers"

module HLS
  # Fragmented MP4 (ISO/IEC 14496-12, as CMAF and HLS use it) for one audio track: an init segment,
  # then fragments of `moof` and `mdat`.
  module FMP4
    TRACK_ID = 1_u32

    # The init segment (`ftyp` and `moov`) for *config*; the track's timescale is its sample rate.
    def self.init(config : TrackConfig) : Bytes
      io = IO::Memory.new
      box(io, "ftyp") do |ftyp|
        ftyp << "iso6"
        ftyp.write_bytes(0_u32, IO::ByteFormat::BigEndian)
        {"iso6", "cmfc", "mp41"}.each { |brand| ftyp << brand }
      end
      box(io, "moov") do |moov|
        full_box(moov, "mvhd") do |mvhd|
          u32(mvhd, 0, 0, 1000, 0)
          u32(mvhd, 0x00010000)
          u16(mvhd, 0x0100, 0)
          u32(mvhd, 0, 0)
          matrix(mvhd)
          6.times { u32(mvhd, 0) }
          u32(mvhd, TRACK_ID + 1)
        end
        box(moov, "trak") do |trak|
          full_box(trak, "tkhd", flags: 3) do |tkhd|
            u32(tkhd, 0, 0, TRACK_ID, 0, 0, 0, 0)
            u16(tkhd, 0, 1, 0x0100, 0)
            matrix(tkhd)
            u32(tkhd, 0, 0)
          end
          box(trak, "mdia") do |mdia|
            full_box(mdia, "mdhd") do |mdhd|
              u32(mdhd, 0, 0, config.sample_rate.to_u32, 0)
              u16(mdhd, 0x55c4, 0) # "und"
            end
            full_box(mdia, "hdlr") do |hdlr|
              u32(hdlr, 0)
              hdlr << "soun"
              u32(hdlr, 0, 0, 0)
              hdlr << "Lurcast\0"
            end
            box(mdia, "minf") do |minf|
              full_box(minf, "smhd") { |smhd| u16(smhd, 0, 0) }
              box(minf, "dinf") do |dinf|
                full_box(dinf, "dref") do |dref|
                  u32(dref, 1)
                  full_box(dref, "url ", flags: 1) { }
                end
              end
              box(minf, "stbl") do |stbl|
                full_box(stbl, "stsd") do |stsd|
                  u32(stsd, 1)
                  sample_entry(stsd, config)
                end
                full_box(stbl, "stts") { |stts| u32(stts, 0) }
                full_box(stbl, "stsc") { |stsc| u32(stsc, 0) }
                full_box(stbl, "stsz") { |stsz| u32(stsz, 0, 0) }
                full_box(stbl, "stco") { |stco| u32(stco, 0) }
              end
            end
          end
        end
        box(moov, "mvex") do |mvex|
          full_box(mvex, "trex") { |trex| u32(trex, TRACK_ID, 1, 0, 0, 0) }
        end
      end
      io.to_slice
    end

    # A fragment (`moof` and `mdat`) with *samples*, each {data, duration in timescale units}, starting
    # at *decode_time*.
    def self.fragment(sequence : UInt32, decode_time : UInt64, samples : Array({Bytes, Int32})) : Bytes
      moof = IO::Memory.new
      box(moof, "moof") do |body|
        full_box(body, "mfhd") { |mfhd| u32(mfhd, sequence) }
        box(body, "traf") do |traf|
          full_box(traf, "tfhd", flags: 0x020000) { |tfhd| u32(tfhd, TRACK_ID) }
          full_box(traf, "tfdt", version: 1) { |tfdt| tfdt.write_bytes(decode_time, IO::ByteFormat::BigEndian) }
          full_box(traf, "trun", flags: 0x000301) do |trun|
            u32(trun, samples.size.to_u32)
            u32(trun, 0) # data offset, set below
            samples.each { |(data, duration)| u32(trun, duration.to_u32, data.size.to_u32) }
          end
        end
      end
      bytes = moof.to_slice
      mdat_size = 8 + samples.sum(&.[0].size)
      result = Bytes.new(bytes.size + mdat_size)
      bytes.copy_to(result)
      # The trun's data offset: from the start of the moof to the first sample.
      offset_position = trun_data_offset_position(bytes)
      IO::ByteFormat::BigEndian.encode((bytes.size + 8).to_u32, result[offset_position, 4])
      IO::ByteFormat::BigEndian.encode(mdat_size.to_u32, result[bytes.size, 4])
      "mdat".to_slice.copy_to(result[bytes.size + 4, 4])
      position = bytes.size + 8
      samples.each do |(data, _)|
        data.copy_to(result[position, data.size])
        position += data.size
      end
      result
    end

    # Where the trun's data_offset field is in a moof written by `fragment`.
    private def self.trun_data_offset_position(moof : Bytes) : Int32
      index = 0
      while index + 8 <= moof.size
        if moof[index + 4, 4] == "trun".to_slice
          return index + 8 + 4 + 4 # box header, version and flags, sample count
        end
        size = IO::ByteFormat::BigEndian.decode(UInt32, moof[index, 4]).to_i
        # Descend into containers; skip other boxes.
        index += {"moof", "traf"}.includes?(String.new(moof[index + 4, 4])) ? 8 : size
      end
      raise "no trun box"
    end

    private def self.sample_entry(io : IO, config : TrackConfig) : Nil
      type = case config.codec
             in .aac?, .mp3? then "mp4a"
             in .opus?       then "Opus"
             in .flac?       then "fLaC"
             end
      box(io, type) do |entry|
        entry.write(Bytes.new(6))
        u16(entry, 1)
        u32(entry, 0, 0)
        u16(entry, config.channels.to_u16, 16, 0, 0)
        rate = config.codec.opus? ? 48_000 : config.sample_rate
        u32(entry, rate <= 0xffff ? (rate.to_u32 << 16) : 0_u32)
        case config.codec
        in .aac?, .mp3? then esds(entry, config)
        in .opus?       then box(entry, "dOps") { |dops| dops.write(HLS::FMP4.dops(config.setup)) }
        in .flac?       then full_box(entry, "dfLa", &.write(config.setup))
        end
      end
    end

    private def self.esds(io : IO, config : TrackConfig) : Nil
      full_box(io, "esds") do |esds|
        specific = config.codec.aac? ? descriptor(0x05, config.setup) : Bytes.empty
        decoder = IO::Memory.new
        decoder.write_byte(config.codec.aac? ? 0x40_u8 : 0x6b_u8)
        decoder.write_byte(0x15_u8) # audio stream
        decoder.write(Bytes.new(3))
        u32(decoder, 0, 0)
        decoder.write(specific)
        es = IO::Memory.new
        u16(es, 0)
        es.write_byte(0_u8)
        es.write(descriptor(0x04, decoder.to_slice))
        es.write(descriptor(0x06, Bytes[0x02]))
        esds.write(descriptor(0x03, es.to_slice))
      end
    end

    # The `dOps` box body for an OpusHead packet (RFC 7845 section 5.1; Opus in ISOBMFF section 4.3.2).
    def self.dops(head : Bytes) : Bytes
      io = IO::Memory.new
      io.write_byte(0_u8)
      io.write_byte(head[9])
      io.write_bytes(IO::ByteFormat::LittleEndian.decode(UInt16, head[10, 2]), IO::ByteFormat::BigEndian)
      io.write_bytes(IO::ByteFormat::LittleEndian.decode(UInt32, head[12, 4]), IO::ByteFormat::BigEndian)
      io.write_bytes(IO::ByteFormat::LittleEndian.decode(Int16, head[16, 2]), IO::ByteFormat::BigEndian)
      io.write_byte(head[18])
      io.write(head[19, 2 + head[9]]) if head[18] != 0 && head.size >= 21 + head[9]
      io.to_slice
    end

    private def self.descriptor(tag : Int32, body : Bytes) : Bytes
      io = IO::Memory.new
      io.write_byte(tag.to_u8)
      # Four length bytes, as most muxers write them.
      size = body.size
      {21, 14, 7}.each { |shift| io.write_byte((0x80 | ((size >> shift) & 0x7f)).to_u8) }
      io.write_byte((size & 0x7f).to_u8)
      io.write(body)
      io.to_slice
    end

    private def self.box(io : IO, type : String, & : IO::Memory ->) : Nil
      body = IO::Memory.new
      yield body
      io.write_bytes((8 + body.size).to_u32, IO::ByteFormat::BigEndian)
      io << type
      io.write(body.to_slice)
    end

    private def self.full_box(io : IO, type : String, version = 0, flags = 0, & : IO::Memory ->) : Nil
      box(io, type) do |body|
        body.write_bytes(((version.to_u32 << 24) | flags.to_u32), IO::ByteFormat::BigEndian)
        yield body
      end
    end

    private def self.matrix(io : IO) : Nil
      u32(io, 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000)
    end

    private def self.u32(io : IO, *values) : Nil
      values.each { |value| io.write_bytes(value.to_u32, IO::ByteFormat::BigEndian) }
    end

    private def self.u16(io : IO, *values) : Nil
      values.each { |value| io.write_bytes(value.to_u16, IO::ByteFormat::BigEndian) }
    end
  end
end
