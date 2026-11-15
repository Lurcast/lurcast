require "../../mp3"
require "../../aac"

# HLS packed-audio segmenter (RFC 8216 section 3.4). Cuts an already
# synchronized MP3 or AAC (ADTS) frame stream into segments on frame
# boundaries, without transcoding, prefixing each with an ID3v2.4 tag that
# carries the segment's MPEG-2 90 kHz start timestamp (and the current title).
module HLS
  enum Codec
    MP3
    AAC
  end

  class Segmenter
    TIMESTAMP_OWNER = "com.apple.streaming.transportStreamTimestamp"
    CLOCK_HZ        = 90_000_i64

    private record Segment, sequence : Int64, duration : Float64, data : Bytes, discontinuity : Bool

    getter codec : Codec

    @segments = Deque(Segment).new
    @mutex = Mutex.new
    @current = IO::Memory.new
    @current_samples = 0_i64
    @current_discontinuity = false
    @pending_discontinuity = false
    @sample_rate : Int32? = nil
    # 90 kHz clock = @base_ticks + @rate_samples converted at the current rate,
    # so a sample-rate change never rescales earlier audio.
    @base_ticks = 0_i64
    @rate_samples = 0_i64
    @free_format_bytes : Int32? = nil
    @next_sequence : Int64

    def initialize(@codec : Codec, @target_seconds : Float64 = 6.0, @window : Int32 = 6, *, first_sequence : Int64 = Time.utc.to_unix)
      @next_sequence = first_sequence
    end

    def write(data : Bytes, title : String = "") : Nil
      @mutex.synchronize do
        offset = 0
        while offset < data.size
          frame = parse_frame(data[offset..])
          break unless frame
          size, samples, rate = frame
          break if offset + size > data.size

          append_frame(data[offset, size], samples, rate, title)
          offset += size
        end
      end
    end

    def playlist(uri_prefix : String) : String?
      @mutex.synchronize do
        return if @segments.empty?

        longest = @segments.max_of(&.duration)
        target = Math.max(@target_seconds.ceil, longest.ceil).to_i
        String.build do |io|
          io << "#EXTM3U\n"
          io << "#EXT-X-VERSION:3\n"
          io << "#EXT-X-TARGETDURATION:" << target << '\n'
          io << "#EXT-X-MEDIA-SEQUENCE:" << @segments.first.sequence << '\n'
          @segments.each do |segment|
            io << "#EXT-X-DISCONTINUITY\n" if segment.discontinuity
            io << "#EXTINF:" << ("%.3f" % segment.duration) << ",\n"
            io << uri_prefix << segment.sequence << '.' << extension << '\n'
          end
        end
      end
    end

    def segment(sequence : Int64) : Bytes?
      @mutex.synchronize do
        @segments.find(&.sequence.==(sequence)).try(&.data)
      end
    end

    def extension : String
      @codec.mp3? ? "mp3" : "aac"
    end

    def content_type : String
      @codec.mp3? ? "audio/mpeg" : "audio/aac"
    end

    def bytesize : Int64
      @mutex.synchronize do
        @segments.sum(0_i64, &.data.size.to_i64) + @current.size
      end
    end

    # Returns {frame_size, samples_per_frame, sample_rate_hz} or nil when the
    # bytes do not start with a usable frame.
    private def parse_frame(data : Bytes) : {Int32, Int32, Int32}?
      case @codec
      in .mp3?
        frame = MP3.parse_frame(data, free_format_bytes: @free_format_bytes)
        return unless frame && frame.frame_size.positive?
        @free_format_bytes = frame.free_format_bytes if frame.free_format_bytes
        {frame.frame_size, frame.samples_per_frame, frame.sample_rate_hz}
      in .aac?
        frame = AAC.parse_header(data)
        return unless frame && frame.transport.adts?
        {frame.frame_size, frame.samples_per_frame, frame.sample_rate_hz}
      end
    end

    private def append_frame(bytes : Bytes, samples : Int32, rate : Int32, title : String) : Nil
      current_rate = @sample_rate
      if current_rate.nil? || current_rate != rate
        if current_rate
          @base_ticks = ticks
          finish_segment
          @pending_discontinuity = true
        end
        @sample_rate = rate
        @rate_samples = 0_i64
      end

      start_segment(title) if @current.size.zero?
      @current.write(bytes)
      @current_samples += samples
      @rate_samples += samples
      finish_segment if current_duration >= @target_seconds
    end

    private def start_segment(title : String) : Nil
      @current_discontinuity = @pending_discontinuity
      @pending_discontinuity = false
      write_id3(@current, ticks, title.delete('\0'))
    end

    private def finish_segment : Nil
      return if @current.size.zero?

      @segments << Segment.new(@next_sequence, current_duration, @current.to_slice.dup, @current_discontinuity)
      @next_sequence += 1
      while @segments.size > @window
        @segments.shift
      end
      @current.clear
      @current_samples = 0_i64
    end

    private def current_duration : Float64
      rate = @sample_rate
      rate ? @current_samples / rate : 0.0
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
