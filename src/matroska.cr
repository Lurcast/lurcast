require "deque"
require "./stream_join"

# Matroska and WebM streams, as live encoders and browsers' MediaRecorder send them: the EBML header,
# a Segment (usually of unknown size), its Info and Tracks, then Clusters of blocks.
module Matroska
  EBML         = 0x1A45DFA3_u32
  SEGMENT      = 0x18538067_u32
  CLUSTER      = 0x1F43B675_u32
  TIMESTAMP    =       0xE7_u32
  SIMPLE_BLOCK =       0xA3_u32
  BLOCK_GROUP  =       0xA0_u32
  TRACKS       = 0x1654AE6B_u32
  TRACK_ENTRY  =       0xAE_u32
  TRACK_NUMBER =       0xD7_u32
  TRACK_TYPE   =       0x83_u32
  VIDEO_TRACK  =          1_u64
  # Elements that sit directly in a Segment; one of them ends a Cluster of unknown size.
  TOP_LEVEL        = {0x114D9B74_u32, 0x1549A966_u32, TRACKS, 0x1C53BB6B_u32, 0x1254C367_u32, 0x1043A770_u32, 0x1941A469_u32, CLUSTER, EBML}
  UNKNOWN_SIZE     = -1_i64
  MAX_HEADER_BYTES = 1 << 20

  # An element's ID (with its marker bits, as the specification writes IDs), the length of the ID
  # and size fields, and the size of its body (`UNKNOWN_SIZE` when the size isn't given).
  record ElementHeader, id : UInt32, length : Int32, size : Int64

  # Reads the element header at the start of *data*; nil when more bytes are needed, and raises
  # `ArgumentError` when the bytes can't be an element header.
  def self.element_header(data : Bytes) : ElementHeader?
    return if data.empty?
    id_length = vint_length(data[0])
    raise ArgumentError.new("invalid element ID") unless id_length && id_length <= 4
    return if data.size < id_length + 1
    id = data[0, id_length].reduce(0_u32) { |value, byte| (value << 8) | byte }
    size_length = vint_length(data[id_length]) || raise ArgumentError.new("invalid element size")
    return if data.size < id_length + size_length
    size, unknown = vint(data[id_length, size_length])
    ElementHeader.new(id, id_length + size_length, unknown ? UNKNOWN_SIZE : size)
  end

  # The value of the variable-length integer in *bytes* (without its marker bit), and whether it
  # is all ones, which means "unknown" for sizes.
  def self.vint(bytes : Bytes) : {Int64, Bool}
    mask = 0xff_u8 >> bytes.size
    value = (bytes[0] & mask).to_i64
    all_ones = (bytes[0] & mask) == mask
    bytes[1..].each do |byte|
      value = (value << 8) | byte
      all_ones &&= byte == 0xff
    end
    {value, all_ones}
  end

  def self.vint_length(first : UInt8) : Int32?
    return if first.zero?
    first.leading_zeros_count.to_i + 1
  end

  def self.unsigned(bytes : Bytes) : UInt64
    bytes.reduce(0_u64) { |value, byte| (value << 8) | byte }
  end

  # Writes a Cluster of unknown size with *timestamp*, so blocks from the middle of a cluster can
  # follow it.
  def self.cluster_header(timestamp : UInt64) : Bytes
    io = IO::Memory.new
    io.write(Bytes[0x1F, 0x43, 0xB6, 0x75, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    io.write_byte(0xE7_u8)
    io.write_byte(0x88_u8)
    io.write_bytes(timestamp, IO::ByteFormat::BigEndian)
    io.to_slice
  end

  # The numbers of the video tracks among the Tracks in *header* (the bytes before the first Cluster).
  def self.video_tracks(header : Bytes) : Set(UInt64)
    tracks = Set(UInt64).new
    each_element(header) do |element, body|
      case element.id
      when SEGMENT, TRACKS
        video_tracks(body).each { |number| tracks << number }
      when TRACK_ENTRY
        number = nil.as(UInt64?)
        type = nil.as(UInt64?)
        each_element(body) do |child, value|
          number = unsigned(value) if child.id == TRACK_NUMBER
          type = unsigned(value) if child.id == TRACK_TYPE
        end
        tracks << number if number && type == VIDEO_TRACK
      end
    end
    tracks
  end

  # Yields each element in *bytes* with its body; an element of unknown size runs to the end.
  private def self.each_element(bytes : Bytes, & : ElementHeader, Bytes ->) : Nil
    offset = 0
    while offset < bytes.size
      element = element_header(bytes[offset..]) || return
      start = offset + element.length
      size = element.size == UNKNOWN_SIZE ? bytes.size - start : Math.min(element.size, (bytes.size - start).to_i64).to_i
      yield element, bytes[start, size]
      offset = start + size
    end
  rescue ArgumentError
  end

  # Join points for a Matroska stream: the start of each Cluster, and each keyframe block inside one,
  # which a listener can start at after a new Cluster header. With video, only video keyframes count,
  # so a picture can be decoded from the first frame.
  class Join < StreamJoin
    # Bytes of a SimpleBlock's body needed to read its track number, timecode and flags.
    BLOCK_PROBE = 11

    private enum State
      TopLevel
      InSegment
      InCluster
      Failed
    end

    private record Mark, offset : Int64, timestamp : UInt64?

    @state = State::TopLevel
    @pending = IO::Memory.new
    @skip = 0_i64
    @capture = IO::Memory.new
    @header : Bytes?
    @video_tracks = Set(UInt64).new
    @cluster_end : Int64?
    @cluster_timestamp = 0_u64
    @points = Deque(Mark).new

    def header : Bytes?
      @header
    end

    def join(from : Int64) : Point?
      header = @header || return
      mark = @points.find(&.offset.>=(from)) || return
      extra = mark.timestamp.try { |timestamp| Matroska.cluster_header(timestamp) } || Bytes.empty
      Point.new(mark.offset, header, extra)
    end

    private def scan(data : Bytes) : Nil
      return if @state.failed?
      offset = 0
      # Skips the rest of an element body, which may span chunks.
      if @skip.positive?
        count = Math.min(@skip, data.size.to_i64).to_i
        capture(data[0, count])
        @skip -= count
        offset = count
      end
      return if offset == data.size

      @pending.write(data[offset..])
      bytes = @pending.to_slice
      # The stream offset of bytes[0].
      base = @position + data.size - bytes.size
      index = 0
      while index < bytes.size
        element = Matroska.element_header(bytes[index..]) || break
        used = step(element, bytes, index, base)
        break unless used
        index += used
        break if @state.failed?
      end
      rest = bytes[index..].dup
      @pending.clear
      @pending.write(rest) unless @state.failed?
    rescue ArgumentError
      fail
    end

    # Handles the element whose header starts at bytes[index]; returns the bytes it consumed, or nil
    # when more are needed.
    private def step(element : ElementHeader, bytes : Bytes, index : Int32, base : Int64) : Int32?
      offset = base + index
      if (finish = @cluster_end) && @state.in_cluster? && offset >= finish
        @state = State::InSegment
        @cluster_end = nil
      end
      if @state.in_cluster? && TOP_LEVEL.includes?(element.id)
        @state = State::InSegment
        @cluster_end = nil
      end

      case @state
      when .top_level?
        case element.id
        when EBML    then skip_body(element, bytes, index)
        when SEGMENT then consume(bytes, index, element.length).tap { @state = State::InSegment }
        else              fail
        end
      when .in_segment?
        case element.id
        when EBML
          restart
          @state = State::TopLevel
          step(element, bytes, index, base)
        when CLUSTER
          finish_header
          @points << Mark.new(offset, nil)
          @state = State::InCluster
          @cluster_end = element.size == UNKNOWN_SIZE ? nil : offset + element.length + element.size
          consume(bytes, index, element.length)
        else
          return fail if element.size == UNKNOWN_SIZE
          skip_body(element, bytes, index)
        end
      when .in_cluster?
        case element.id
        when TIMESTAMP
          return if bytes.size < index + element.length + element.size
          @cluster_timestamp = Matroska.unsigned(bytes[index + element.length, element.size.to_i])
          consume(bytes, index, element.length + element.size.to_i)
        when SIMPLE_BLOCK, BLOCK_GROUP
          probe = Math.min(element.size, BLOCK_PROBE.to_i64).to_i
          return if bytes.size < index + element.length + probe
          @points << Mark.new(offset, @cluster_timestamp) if starts_here?(element, bytes[index + element.length, probe])
          skip_body(element, bytes, index)
        else
          return fail if element.size == UNKNOWN_SIZE
          skip_body(element, bytes, index)
        end
      end
    end

    # Whether a listener can start at this block.
    private def starts_here?(element : ElementHeader, body : Bytes) : Bool
      return @video_tracks.empty? if element.id == BLOCK_GROUP
      length = Matroska.vint_length(body[0]) || return false
      return false if body.size < length + 3
      track, _ = Matroska.vint(body[0, length])
      keyframe = (body[length + 2] & 0x80) != 0
      @video_tracks.empty? ? keyframe : keyframe && @video_tracks.includes?(track.to_u64)
    end

    private def consume(bytes : Bytes, index : Int32, count : Int32) : Int32
      capture(bytes[index, count])
      count
    end

    # Consumes the element header and as much of the body as is here; the rest is skipped as it arrives.
    private def skip_body(element : ElementHeader, bytes : Bytes, index : Int32) : Int32
      available = bytes.size - index - element.length
      body = Math.min(element.size, available.to_i64).to_i
      @skip = element.size - body
      consume(bytes, index, element.length + body)
    end

    private def capture(bytes : Bytes) : Nil
      return if @header
      @capture.write(bytes)
      fail if @capture.size > MAX_HEADER_BYTES
    end

    private def finish_header : Nil
      return if @header
      header = @capture.to_slice.dup
      @header = header
      @video_tracks = Matroska.video_tracks(header)
      @capture = IO::Memory.new
    end

    # A new EBML header: the source started a new stream, so its headers replace the old ones.
    private def restart : Nil
      @header = nil
      @capture = IO::Memory.new
      @points.clear
      @video_tracks.clear
      @cluster_end = nil
      @cluster_timestamp = 0_u64
    end

    private def fail : Nil
      @state = State::Failed
      @pending.clear
      @header = nil
      @points.clear
      nil
    end

    private def prune(before : Int64) : Nil
      while (first = @points.first?) && first.offset < before
        @points.shift
      end
    end
  end
end
