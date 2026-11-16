require "./framers"
require "./fmp4"

# HLS segmenter (RFC 8216, with the low-latency extensions of its second edition). Cuts a mount's
# frames into segments on frame boundaries, without transcoding:
#
# - packed audio (section 3.4) for MP3 and AAC: each segment is the frames, after an ID3v2.4 tag
#   with the segment's MPEG-2 90 kHz start timestamp and the current title;
# - fragmented MP4 for AAC, Opus and FLAC, with an init segment (`EXT-X-MAP`).
#
# With *part_seconds*, segments are made of partial segments of at most that length, published as
# soon as each is complete (low-latency HLS, fMP4 only).
module HLS
  enum Container
    Packed
    FMP4
  end

  class Segmenter
    TIMESTAMP_OWNER = "com.apple.streaming.transportStreamTimestamp"
    CLOCK_HZ        = 90_000_i64
    # Parts are listed for this many of the newest segments (about three target durations).
    PART_SEGMENTS = 3

    private class Part
      getter data : Bytes
      getter duration : Float64

      def initialize(@data : Bytes, @duration : Float64)
      end
    end

    private class Segment
      getter sequence : Int64
      getter parts = [] of Part
      property data = Bytes.empty
      property duration = 0.0
      getter? discontinuity : Bool
      getter init_id : Int32

      def initialize(@sequence : Int64, @discontinuity : Bool, @init_id : Int32)
      end
    end

    getter container : Container
    getter framer : Framer

    @segments = Deque(Segment).new
    @mutex = Mutex.new
    @waiters = [] of Channel(Nil)
    @current : Segment?
    @packed = IO::Memory.new
    @part_samples = [] of {Bytes, Int32}
    @part_frames = 0_i64
    @segment_samples = 0_i64
    @pending_discontinuity = false
    @config : TrackConfig?
    @inits = {} of Int32 => Bytes
    @init_id = 0
    @sample_rate : Int32? = nil
    @fragments = 0_u32
    # Discontinuities that have left the playlist (EXT-X-DISCONTINUITY-SEQUENCE).
    @discontinuity_sequence = 0
    # 90 kHz clock = @base_ticks + @rate_samples converted at the current rate, so a sample-rate
    # change never rescales earlier audio.
    @base_ticks = 0_i64
    @rate_samples = 0_i64
    @decode_time = 0_u64
    @next_sequence : Int64

    # Packed audio from MP3 or ADTS AAC frames.
    def self.new(codec : Codec, target_seconds : Float64 = 6.0, window : Int32 = 6, *, first_sequence : Int64 = Time.utc.to_unix)
      framer = codec.mp3? ? MP3Framer.new : ADTSFramer.new
      new(framer, Container::Packed, target_seconds, window, first_sequence: first_sequence)
    end

    def initialize(@framer : Framer, @container : Container, @target_seconds : Float64 = 6.0, @window : Int32 = 6,
                   *, @part_seconds : Float64? = nil, first_sequence : Int64 = Time.utc.to_unix)
      raise ArgumentError.new("partial segments need fMP4") if @part_seconds && @container.packed?
      @next_sequence = first_sequence
    end

    def codec : Codec
      @framer.codec
    end

    def low_latency? : Bool
      !@part_seconds.nil?
    end

    def write(data : Bytes, title : String = "") : Nil
      changed = false
      @mutex.synchronize do
        @framer.write(data) do |frame|
          changed = true if append(frame, title.delete('\0'))
        end
      end
      notify if changed
    end

    # Why the stream can't be served over HLS, once that is known.
    def unsupported : String?
      @mutex.synchronize { @framer.unsupported }
    end

    def playlist(uri_prefix : String) : String?
      @mutex.synchronize do
        return if @segments.empty?

        longest = @segments.max_of(&.duration)
        target = Math.max(@target_seconds.ceil, longest.ceil).to_i
        String.build do |io|
          io << "#EXTM3U\n"
          io << "#EXT-X-VERSION:" << (@container.packed? ? 3 : 7) << '\n'
          io << "#EXT-X-TARGETDURATION:" << target << '\n'
          if part = @part_seconds
            io << "#EXT-X-PART-INF:PART-TARGET=" << ("%.3f" % part) << '\n'
            io << "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=" << ("%.3f" % (part * 3)) << '\n'
          end
          io << "#EXT-X-MEDIA-SEQUENCE:" << @segments.first.sequence << '\n'
          io << "#EXT-X-DISCONTINUITY-SEQUENCE:" << @discontinuity_sequence << '\n' if @discontinuity_sequence.positive?
          map = nil.as(Int32?)
          with_parts = @segments.size - PART_SEGMENTS
          @segments.each_with_index do |segment, index|
            map = segment_tags(io, segment, map, uri_prefix)
            parts(io, segment, uri_prefix) if low_latency? && index >= with_parts
            io << "#EXTINF:" << ("%.3f" % segment.duration) << ",\n"
            io << uri_prefix << segment.sequence << '.' << extension << '\n'
          end
          if low_latency?
            if current = @current
              segment_tags(io, current, map, uri_prefix)
              parts(io, current, uri_prefix)
              hint = {current.sequence, current.parts.size}
            else
              hint = {@next_sequence, 0}
            end
            io << "#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"" << uri_prefix << hint[0] << '.' << hint[1] << '.' << extension << "\"\n"
          end
        end
      end
    end

    def segment(sequence : Int64) : Bytes?
      @mutex.synchronize do
        @segments.find(&.sequence.==(sequence)).try(&.data)
      end
    end

    def part(sequence : Int64, index : Int32) : Bytes?
      @mutex.synchronize do
        segment = @current.try { |current| current if current.sequence == sequence } || @segments.find(&.sequence.==(sequence))
        segment.try(&.parts[index]?).try(&.data)
      end
    end

    def init(id : Int32) : Bytes?
      @mutex.synchronize { @inits[id]? }
    end

    # The media sequence number of the segment being written.
    def next_sequence : Int64
      @mutex.synchronize { @current.try(&.sequence) || @next_sequence }
    end

    # Blocks until segment *sequence* is complete, or with *part*, until that part of it is (for
    # blocking playlist reloads and preload hints), at most *limit*. Returns whether it happened.
    def wait_for(sequence : Int64, part : Int32? = nil, limit : Time::Span = 10.seconds) : Bool
      deadline = Time.instant + limit
      loop do
        channel = Channel(Nil).new
        ready = @mutex.synchronize do
          available?(sequence, part) || (@waiters << channel; false)
        end
        return true if ready
        remaining = deadline - Time.instant
        return false unless remaining.positive?
        select
        when channel.receive?
        when timeout(remaining)
          return @mutex.synchronize { available?(sequence, part) }
        end
      end
    end

    def extension : String
      return "m4s" if @container.fmp4?
      codec.mp3? ? "mp3" : "aac"
    end

    def content_type : String
      return "audio/mp4" if @container.fmp4?
      codec.mp3? ? "audio/mpeg" : "audio/aac"
    end

    # The `CODECS` attribute for a multivariant playlist, once the audio format is known.
    def codecs : String?
      @mutex.synchronize { @config.try(&.codecs) }
    end

    # The highest bit rate of a segment in the playlist, in bits per second.
    def peak_bandwidth : Int32?
      @mutex.synchronize do
        @segments.compact_map { |segment| (segment.data.size * 8 / segment.duration).ceil.to_i if segment.duration.positive? }.max?
      end
    end

    # The average bit rate of the segments in the playlist, in bits per second.
    def average_bandwidth : Int32?
      @mutex.synchronize do
        seconds = @segments.sum(&.duration)
        (@segments.sum(&.data.size) * 8 / seconds).ceil.to_i if seconds.positive?
      end
    end

    def bytesize : Int64
      @mutex.synchronize do
        @segments.sum(0_i64, &.data.size.to_i64) + @packed.size + (@current.try(&.parts.sum(&.data.size)) || 0)
      end
    end

    private def available?(sequence : Int64, part : Int32?) : Bool
      return true if @segments.any? { |segment| segment.sequence >= sequence }
      current = @current
      return false unless part && current && current.sequence == sequence
      current.parts.size > part
    end

    private def notify : Nil
      waiters = @mutex.synchronize { @waiters.dup.tap { @waiters.clear } }
      waiters.each(&.close)
    end

    private def segment_tags(io : IO, segment : Segment, map : Int32?, uri_prefix : String) : Int32?
      io << "#EXT-X-DISCONTINUITY\n" if segment.discontinuity?
      return map if @container.packed? || map == segment.init_id
      io << "#EXT-X-MAP:URI=\"" << uri_prefix << "init-" << segment.init_id << ".mp4\"\n"
      segment.init_id
    end

    private def parts(io : IO, segment : Segment, uri_prefix : String) : Nil
      segment.parts.each_with_index do |part, index|
        io << "#EXT-X-PART:DURATION=" << ("%.5f" % part.duration) << ",URI=\"" << uri_prefix << segment.sequence << '.' << index << '.' << extension << "\",INDEPENDENT=YES\n"
      end
    end

    # Adds a frame; returns whether a part or segment was published.
    private def append(frame : Frame, title : String) : Bool
      published = false
      config = @framer.config
      rate = frame.sample_rate
      current_rate = @sample_rate
      if current_rate.nil? || current_rate != rate || (@container.fmp4? && !config.try(&.same?(@config)))
        if current_rate
          @base_ticks = ticks
          published = finish_segment
          @pending_discontinuity = true
        end
        @sample_rate = rate
        @rate_samples = 0_i64
        @decode_time = (@base_ticks * rate // CLOCK_HZ).to_u64
        if @container.fmp4? && config
          @init_id += 1
          @inits[@init_id] = FMP4.init(config)
          @inits.reject! { |id, _| id < @init_id - @window - 1 }
        end
        @config = config
      end

      start_segment(title) unless @current
      if @container.packed?
        @packed.write(frame.data)
      else
        # Copied: a mount reuses the buffer it hands its taps, and samples wait for their part.
        @part_samples << {frame.payload.dup, frame.samples}
      end
      @part_frames += frame.samples
      @segment_samples += frame.samples
      @rate_samples += frame.samples

      if part = @part_seconds
        # Ends the part when the next frame (likely as long as this one) would make it too long, and
        # the segment at the part boundary nearest its target, so segments are made of whole parts.
        if (@part_frames + frame.samples) / rate > part + 1e-9
          published = finish_part || published
          published = finish_segment || published if @segment_samples / rate >= @target_seconds - part / 2
        end
      elsif @segment_samples / rate >= @target_seconds - 1e-9
        published = finish_segment || published
      end
      published
    end

    private def start_segment(title : String) : Nil
      @current = Segment.new(@next_sequence, @pending_discontinuity, @init_id)
      @pending_discontinuity = false
      write_id3(@packed, ticks, title) if @container.packed?
    end

    # Publishes the samples since the last part as one fragment.
    private def finish_part : Bool
      current = @current
      return false if @part_samples.empty? || current.nil?
      rate = @sample_rate || return false
      @fragments += 1
      data = FMP4.fragment(@fragments, @decode_time, @part_samples)
      @decode_time += @part_frames.to_u64
      current.parts << Part.new(data, @part_frames / rate)
      @part_samples.clear
      @part_frames = 0_i64
      true
    end

    private def finish_segment : Bool
      current = @current || return false
      rate = @sample_rate || return false
      if @container.packed?
        current.data = @packed.to_slice.dup
        @packed.clear
        @part_frames = 0_i64
      else
        finish_part
        current.data = concatenate(current.parts)
      end
      current.duration = @segment_samples / rate
      @segment_samples = 0_i64
      @current = nil
      return false if current.data.empty?

      @segments << current
      @next_sequence += 1
      while @segments.size > @window
        @discontinuity_sequence += 1 if @segments.shift.discontinuity?
      end
      true
    end

    private def concatenate(parts : Array(Part)) : Bytes
      bytes = Bytes.new(parts.sum(&.data.size))
      offset = 0
      parts.each do |part|
        part.data.copy_to(bytes[offset, part.data.size])
        offset += part.data.size
      end
      bytes
    end

    private def ticks : Int64
      rate = @sample_rate
      return @base_ticks unless rate
      @base_ticks + @rate_samples * CLOCK_HZ // rate
    end

    private def write_id3(io : IO, timestamp : Int64, title : String) : Nil
      frames = IO::Memory.new
      priv = IO::Memory.new
      priv << TIMESTAMP_OWNER
      priv.write_byte(0_u8)
      priv.write_bytes(timestamp.to_u64! & 0x1_ffff_ffff_u64, IO::ByteFormat::BigEndian)
      write_id3_frame(frames, "PRIV", priv.to_slice)
      unless title.empty?
        text = IO::Memory.new
        text.write_byte(3_u8) # UTF-8
        text << title
        write_id3_frame(frames, "TIT2", text.to_slice)
      end

      io << "ID3"
      io.write(Bytes[4, 0, 0]) # version 2.4.0, no flags
      write_syncsafe(io, frames.size)
      io.write(frames.to_slice)
    end

    private def write_id3_frame(io : IO, id : String, body : Bytes) : Nil
      io << id
      write_syncsafe(io, body.size)
      io.write(Bytes[0, 0])
      io.write(body)
    end

    private def write_syncsafe(io : IO, value : Int32) : Nil
      {21, 14, 7, 0}.each { |shift| io.write_byte(((value >> shift) & 0x7f).to_u8) }
    end
  end
end
