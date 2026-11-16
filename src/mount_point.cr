require "json"
require "deque"
require "http/headers"
require "mime/media_type"
require "./aac"
require "./flac"
require "./matroska"
require "./mp3"
require "./ogg"
require "./source_protocol"

# Receives every chunk a mount publishes, after frame synchronization: whole MP3 or AAC frames, or
# Ogg and other data as the source sent it. `receive` runs while the mount holds its broadcast lock,
# so it must return quickly; hand slow work such as file writes to another fiber.
abstract class AudioTap
  abstract def receive(data : Bytes) : Nil
end

class MountPoint
  DEFAULT_BURST_SIZE        =  65_536
  DEFAULT_QUEUE_SIZE        = 524_288
  DEFAULT_METADATA_INTERVAL =    8192
  EMPTY_METADATA_BLOCK      = Bytes[0_u8]

  class ListenerQueue
    getter capacity : Int32

    @packets = Deque(Bytes).new
    @ready = Channel(Bool).new(1)
    @mutex = Mutex.new
    @bytesize = 0
    @closed = false

    def initialize(@capacity : Int32)
      raise ArgumentError.new("listener queue capacity must be positive") unless @capacity.positive?
    end

    def enqueue(packet : Bytes) : Bool
      added = @mutex.synchronize do
        if @closed || packet.size > @capacity - @bytesize
          false
        else
          @packets << packet
          @bytesize += packet.size
          true
        end
      end
      signal if added
      added
    end

    def receive? : Bytes?
      loop do
        packet, closed = @mutex.synchronize do
          if packet = @packets.shift?
            @bytesize -= packet.size
            {packet, false}
          else
            {nil, @closed}
          end
        end
        return packet if packet
        return if closed
        @ready.receive?
      end
    end

    def clear
      @mutex.synchronize do
        @packets.clear
        @bytesize = 0
      end
    end

    def bytesize : Int32
      @mutex.synchronize { @bytesize }
    end

    def closed? : Bool
      @mutex.synchronize { @closed }
    end

    def close
      changed = @mutex.synchronize do
        if @closed
          false
        else
          @closed = true
          @packets.clear
          @bytesize = 0
          true
        end
      end
      @ready.close if changed
    end

    private def signal
      select
      when @ready.send(true)
      else
      end
    rescue Channel::ClosedError
    end
  end

  class Listener
    getter io : IO
    getter address : String
    getter requested_mount : String
    getter queue : ListenerQueue
    getter id : Int64
    getter user_agent : String
    getter connected_at : Time::Instant = Time.instant
    getter metadata_interval : Int32
    property remaining : Int32
    getter? wants_metadata : Bool
    # Set while the listener has a stream's headers but waits for a place to start the audio.
    property? awaiting_join : Bool = false
    @metadata_version = Atomic(UInt64).new(UInt64::MAX)
    @owner : MountPoint
    @owner_mutex = Mutex.new
    @finished = Channel(Nil).new
    @bytes_sent = Atomic(Int64).new(0_i64)
    @billed_bytes = Atomic(Int64).new(0_i64)
    getter started_at : Time = Time.utc
    # ISO 3166-1 country code, when an extension provides listener locations.
    getter country : String?

    def initialize(
      @io : IO,
      @address : String,
      @wants_metadata : Bool,
      @requested_mount : String,
      @owner : MountPoint,
      queue_size = DEFAULT_QUEUE_SIZE,
      @metadata_interval = DEFAULT_METADATA_INTERVAL,
      @id = 0_i64,
      @user_agent = "",
      @country = nil,
    )
      @queue = ListenerQueue.new(queue_size)
      @remaining = @metadata_interval
    end

    # The mount currently feeding this listener; it changes when listeners move to a fallback or another mount.
    def owner : MountPoint
      @owner_mutex.synchronize { @owner }
    end

    def owner=(mount : MountPoint)
      @owner_mutex.synchronize { @owner = mount }
    end

    def closed? : Bool
      @queue.closed? || @io.closed?
    end

    def connected_seconds : Int64
      (Time.instant - @connected_at).total_seconds.to_i64
    end

    def bytes_sent : Int64
      @bytes_sent.get(:relaxed)
    end

    protected def count_bytes(size : Int32)
      @bytes_sent.add(size.to_i64, :relaxed)
    end

    # Bytes sent since the previous call, so usage can be metered while the listener is connected.
    def take_unbilled_bytes : Int64
      sent = bytes_sent
      sent - @billed_bytes.swap(sent)
    end

    def metadata_version : UInt64
      @metadata_version.get(:relaxed)
    end

    def metadata_version=(version : UInt64)
      @metadata_version.set(version, :relaxed)
    end

    # Blocks until the listener is closed, or until *limit* elapses.
    def wait_closed(limit : Time::Span? = nil) : Nil
      if limit
        select
        when @finished.receive?
        when timeout(limit)
        end
      else
        @finished.receive?
      end
    end

    def close
      @finished.close
      @queue.close rescue nil
      @io.close unless @io.closed?
    rescue IO::Error
    end
  end

  class OggLogicalStream
    property packet = IO::Memory.new
    property expected_headers : Int32 = 0
    property header_packets : Int32 = 0
    property last_header_sequence : UInt32 = 0_u32
    property? headers_complete : Bool = false
    property? eos : Bool = false
  end

  record OggPage, offset : Int32, serial : UInt32, sequence : UInt32, header_type : UInt8
  record StationDetails, name : String, description : String, genre : String, url : String, listed : Bool
  record Metadata, song : String, updated_at : Time?
  record ListenerInfo, id : Int64, address : String, user_agent : String, connected_seconds : Int64, country : String? = nil do
    include JSON::Serializable
  end
  record PlayedSong, title : String, played_at : Time do
    include JSON::Serializable
  end

  DEFAULT_SONG_HISTORY_SIZE = 10

  getter mount : String
  @content_type = "audio/mpeg"
  getter start_time : Time = Time.utc
  getter metadata_interval : Int32
  @media_type = "audio/mpeg"
  @bitrate = Atomic(Int32).new(128)
  @bytes_sent = Atomic(UInt64).new(0_u64)
  @total_connections : UInt64 = 0_u64
  @peak_listeners : Int32 = 0

  @source : IO?
  @source_protocol = SourceProtocol::Unknown
  @source_mutex = Mutex.new
  @name : String = "Lurcast Stream"
  @genre : String = "Various"
  @url : String = ""
  @description : String = ""
  @listed : Bool = false
  @station_mutex = Mutex.new
  @current_song = ""
  @metadata_block : Bytes = EMPTY_METADATA_BLOCK
  @metadata_version = 0_u64
  @metadata_updated_at : Time?
  @song_history = Deque(PlayedSong).new
  @metadata_mutex = Mutex.new
  @listeners = {} of IO => Listener
  @listeners_mutex = Mutex.new
  @broadcast_mutex = Mutex.new
  @buffer : Bytes
  @buffer_start = 0
  @buffer_size = 0
  @buffer_mutex = Mutex.new
  @ogg_sync = Ogg::Sync.new
  @ogg_headers = IO::Memory.new
  @ogg_streams = {} of UInt32 => OggLogicalStream
  @ogg_data_started = false
  @mp3_info : MP3::Frame?
  @mp3_free_format_bytes : Int32?
  @frame_pending = IO::Memory.new
  @frame_output = IO::Memory.new
  @frame_synced = false
  @taps = [] of AudioTap
  @aac_transport : AAC::Transport?
  # Join points for formats whose listeners need headers first (native FLAC, Matroska and WebM).
  @join : StreamJoin?

  def initialize(
    @mount : String,
    burst_size = DEFAULT_BURST_SIZE,
    @queue_size = DEFAULT_QUEUE_SIZE,
    @metadata_interval = DEFAULT_METADATA_INTERVAL,
    @song_history_size = DEFAULT_SONG_HISTORY_SIZE,
  )
    raise ArgumentError.new("stream buffer sizes and metadata interval must be positive") unless {burst_size, @queue_size, @metadata_interval}.all?(&.positive?)
    raise ArgumentError.new("song history size must not be negative") if @song_history_size.negative?
    raise ArgumentError.new("burst size must not exceed queue size") if burst_size > @queue_size
    @buffer = Bytes.new(burst_size)
  end

  def connect_source(io : IO, protocol : SourceProtocol)
    @source_mutex.synchronize do
      @source = io
      @source_protocol = protocol
    end
    @broadcast_mutex.synchronize { @join = new_join }
  end

  def source : IO?
    @source_mutex.synchronize { @source }
  end

  def source_protocol : SourceProtocol
    @source_mutex.synchronize { @source_protocol }
  end

  def has_source? : Bool
    @source_mutex.synchronize { @source.try { |socket| !socket.closed? } || false }
  end

  def apply_headers(headers : HTTP::Headers)
    @station_mutex.synchronize do
      @name = headers["Ice-Name"]? || headers["Icy-Name"]? || headers["X-Audiocast-Name"]? || @name
      @genre = headers["Ice-Genre"]? || headers["Icy-Genre"]? || headers["X-Audiocast-Genre"]? || @genre
      @url = headers["Ice-URL"]? || headers["Icy-URL"]? || headers["X-Audiocast-URL"]? || @url
      @description = headers["Ice-Description"]? || headers["Icy-Description"]? || headers["X-Audiocast-Description"]? || @description
      public = headers["Ice-Public"]? || headers["Icy-Public"]? || headers["Icy-Pub"]? || headers["X-Audiocast-Public"]? || "0"
      @listed = public.downcase.in?("1", "true", "yes")
    end
    if content_type = headers["Content-Type"]? || headers["Ice-Content"]? || headers["Icy-Content"]?
      media_type = MIME::MediaType.parse?(content_type).try(&.media_type) || content_type.partition(';')[0].downcase
      previous_media_type = @station_mutex.synchronize do
        previous = @media_type
        @content_type = content_type
        @media_type = media_type
        previous
      end
      reset_frame_sync if media_type != previous_media_type
    end
    if bitrate = headers["Ice-Bitrate"]? || headers["Icy-Br"]? || headers["X-Audiocast-Bitrate"]?
      @bitrate.set(bitrate.to_i? || self.bitrate, :relaxed)
    end
  end

  def update_station(name : String? = nil, description : String? = nil, genre : String? = nil, url : String? = nil, listed : Bool? = nil)
    @station_mutex.synchronize do
      @name = name if name
      @description = description if description
      @genre = genre if genre
      @url = url if url
      @listed = listed unless listed.nil?
    end
  end

  def station_details : StationDetails
    @station_mutex.synchronize { StationDetails.new(@name, @description, @genre, @url, @listed) }
  end

  def listed : Bool
    @station_mutex.synchronize { @listed }
  end

  def listener_count : Int32
    @listeners_mutex.synchronize { @listeners.size }
  end

  def listener_stats : Tuple(Int32, Int32, UInt64)
    @listeners_mutex.synchronize { {@listeners.size, @peak_listeners, @total_connections} }
  end

  def bytes_sent : UInt64
    @bytes_sent.get(:relaxed)
  end

  def bitrate : Int32
    @bitrate.get(:relaxed)
  end

  def listener_addresses : Array(String)
    @listeners_mutex.synchronize do
      @listeners.map { |_io, listener| listener.address }
    end
  end

  def listener_details : Array(ListenerInfo)
    @listeners_mutex.synchronize do
      @listeners.values.map do |listener|
        ListenerInfo.new(listener.id, listener.address, listener.user_agent, listener.connected_seconds, listener.country)
      end
    end.sort_by!(&.id)
  end

  # Listeners per country code; listeners without a known country count under "".
  def listener_countries : Hash(String, Int32)
    @listeners_mutex.synchronize do
      @listeners.each_value.each_with_object(Hash(String, Int32).new(0)) do |listener, counts|
        counts[listener.country || ""] += 1
      end
    end
  end

  def unique_listener_count : Int32
    @listeners_mutex.synchronize { @listeners.each_value.map(&.address).to_set.size }
  end

  def average_listen_seconds : Int64
    @listeners_mutex.synchronize do
      next 0_i64 if @listeners.empty?
      @listeners.each_value.sum(&.connected_seconds) // @listeners.size
    end
  end

  # Disconnects the listener with *id*; returns whether it was connected to this mount.
  def kick_listener(id : Int64) : Bool
    io = @listeners_mutex.synchronize { @listeners.find { |_io, listener| listener.id == id }.try(&.first) }
    return false unless io
    remove_listener(io)
    true
  end

  # Disconnects every listener connected from *address*; returns how many were removed.
  def kick_listeners_from(address : String) : Int32
    ios = @listeners_mutex.synchronize { @listeners.compact_map { |io, listener| io if listener.address == address } }
    ios.each { |io| remove_listener(io) }
    ios.size
  end

  def listener_snapshot : Array(Listener)
    @listeners_mutex.synchronize { @listeners.values }
  end

  def includes_listener?(io : IO) : Bool
    @listeners_mutex.synchronize { @listeners.has_key?(io) }
  end

  def content_type : String
    @station_mutex.synchronize { @content_type }
  end

  def supports_icy_metadata? : Bool
    media_type.in?("audio/mpeg", "audio/mp3", "audio/aac", "audio/aacp")
  end

  def mp3_info : MP3::Frame?
    @broadcast_mutex.synchronize { @mp3_info }
  end

  def compatible_with?(other : MountPoint) : Bool
    stream_format == other.stream_format
  end

  def add_listener(io : IO, address : String, wants_metadata : Bool, requested_mount = @mount, *, id = 0_i64, user_agent = "", intro = Bytes.empty, country : String? = nil) : Listener
    listener = Listener.new(io, address, wants_metadata, requested_mount, self, @queue_size, @metadata_interval, id, user_agent, country)

    @broadcast_mutex.synchronize do
      burst, waiting = listener_start
      listener.awaiting_join = waiting
      @listeners_mutex.synchronize do
        @listeners[io] = listener
        @total_connections += 1
        @peak_listeners = Math.max(@peak_listeners, @listeners.size)
      end
      spawn write_listener(listener, intro, burst)
    end
    listener
  end

  def remove_listener(io : IO)
    listener = @broadcast_mutex.synchronize do
      @listeners_mutex.synchronize { @listeners.delete(io) }
    end
    if listener
      listener.close
    elsif !io.closed?
      io.close
    end
  rescue IO::Error
  end

  def detach_listeners(requested_mount : String? = nil, *, id : Int64? = nil) : Array(Listener)
    @broadcast_mutex.synchronize do
      @listeners_mutex.synchronize do
        listeners = @listeners.compact_map do |_io, listener|
          next if id && listener.id != id
          listener if requested_mount.nil? || listener.requested_mount == requested_mount
        end
        listeners.each { |listener| @listeners.delete(listener.io) }
        listeners
      end
    end
  end

  def adopt_listeners(listeners : Array(Listener))
    return if listeners.empty?
    @broadcast_mutex.synchronize do
      burst, waiting = listener_start
      @listeners_mutex.synchronize do
        listeners.each do |listener|
          next if listener.io.closed?
          listener.queue.clear
          listener.metadata_version = UInt64::MAX
          listener.awaiting_join = waiting
          unless burst.empty? || listener.queue.enqueue(burst)
            listener.close
            next
          end
          listener.owner = self
          @listeners[listener.io] = listener
        end
        @peak_listeners = Math.max(@peak_listeners, @listeners.size)
      end
    end
  end

  def close_listeners
    detach_listeners.each(&.close)
  end

  def publish(data : Bytes)
    return if data.empty?

    @broadcast_mutex.synchronize do
      stream_data = synchronize_audio(data)
      return if stream_data.empty?

      capture_mp3_info(stream_data) if mp3?
      @aac_transport ||= AAC.parse_header(stream_data).try(&.transport) if aac?
      capture_ogg_headers(stream_data) if ogg?
      join = @join
      chunk_start = join.try(&.position) || 0_i64
      join.try(&.feed(stream_data))
      append_to_buffer(stream_data)
      @taps.each(&.receive(stream_data))
      dead = nil.as(Array(Listener)?)
      @listeners_mutex.synchronize do
        return if @listeners.empty?
        shared_packet = stream_data.dup
        joined = nil.as(Bytes?)
        @listeners.each_value do |listener|
          packet = shared_packet
          if listener.awaiting_join?
            joined ||= join.try { |active| join_packet(active, chunk_start, stream_data) } || Bytes.empty
            next if joined.empty?
            packet = joined
            listener.awaiting_join = false
          end
          unless listener.queue.enqueue(packet)
            (dead ||= [] of Listener) << listener
          end
        end
        if dead
          dead.each { |listener| @listeners.delete(listener.io) }
        end
      end
      dead.try { |listeners| listeners.each(&.close) }
    end
  end

  # Called after the song changes, outside the metadata lock.
  property on_song_change : Proc(String, Time, Nil)?

  def update_metadata(song : String)
    value = song.gsub('\0', ' ').strip
    changed_at = @metadata_mutex.synchronize do
      if value != @current_song
        now = Time.utc
        @current_song = value
        @metadata_block = build_metadata_block(value)
        @metadata_version &+= 1_u64
        @metadata_updated_at = now
        record_played_song(value, now)
        now
      end
    end
    if changed_at && !value.empty?
      @on_song_change.try(&.call(value, changed_at))
    end
  end

  # Most recent first.
  def song_history : Array(PlayedSong)
    @metadata_mutex.synchronize { @song_history.to_a }
  end

  def current_song : String
    @metadata_mutex.synchronize { @current_song }
  end

  def metadata : Metadata
    @metadata_mutex.synchronize { Metadata.new(@current_song, @metadata_updated_at) }
  end

  # Starts feeding *tap* everything this mount publishes. With *burst*, it first gets the buffered
  # audio a new listener would get, so it starts on a frame or page boundary with no gap.
  def add_tap(tap : AudioTap, burst = false) : Nil
    @broadcast_mutex.synchronize do
      tap.receive(initial_burst) if burst
      @taps << tap
    end
  end

  def remove_tap(tap : AudioTap) : Nil
    @broadcast_mutex.synchronize { @taps.delete(tap) }
  end

  # The stream's format name: "mp3", "aac" (ADTS or LATM), "ogg", or the media type for anything else.
  def format : String
    stream_format
  end

  # Whether AAC frames use the ADTS transport, which HLS packed audio requires.
  def adts? : Bool
    @aac_transport == AAC::Transport::ADTS
  end

  def initial_burst : Bytes
    return listener_start[0] if @join.try(&.header)
    audio = buffered_audio
    return align_mp3(audio) if mp3?
    return align_aac(audio) if aac?
    return ogg_burst(audio) if ogg?
    audio
  end

  # The audio a new listener starts with, and whether it must wait for a join point before getting
  # more: with a native FLAC or Matroska stream, the headers and then the stream from a clean boundary.
  private def listener_start : {Bytes, Bool}
    join = @join
    header = join.try(&.header)
    return {initial_burst, false} unless join && header
    audio = buffered_audio
    from = join.position - audio.size
    point = join.join(from) || return {header, true}
    tail = audio[point.offset - from..]
    result = Bytes.new(point.header.size + point.extra.size + tail.size)
    point.header.copy_to(result)
    point.extra.copy_to(result[point.header.size, point.extra.size])
    tail.copy_to(result[point.header.size + point.extra.size, tail.size])
    {result, false}
  end

  # The packet for a listener waiting to join: from the first join point in this chunk, if any.
  private def join_packet(join : StreamJoin, chunk_start : Int64, data : Bytes) : Bytes?
    point = join.join(chunk_start) || return
    return unless point.offset < chunk_start + data.size
    tail = data[point.offset - chunk_start..]
    result = Bytes.new(point.extra.size + tail.size)
    point.extra.copy_to(result)
    tail.copy_to(result[point.extra.size, tail.size])
    result
  end

  private def new_join : StreamJoin?
    window = @buffer.size * 2
    if flac?
      FLAC::Join.new(window)
    elsif matroska?
      Matroska::Join.new(window)
    end
  end

  def disconnect
    disconnect_source
    close_listeners
  end

  def disconnect_source
    source = @source_mutex.synchronize do
      current = @source
      @source = nil
      current
    end
    source.try(&.close)
  end

  def close_source
    source.try(&.close)
  end

  def uptime_seconds : Int64
    (Time.utc - @start_time).total_seconds.to_i64
  end

  private def record_played_song(title : String, played_at : Time)
    return if title.empty? || @song_history_size.zero?
    @song_history.unshift(PlayedSong.new(title, played_at))
    @song_history.pop if @song_history.size > @song_history_size
  end

  # Listeners keep their own ICY interval because players cannot change metaint mid-stream,
  # while metadata and byte counts follow whichever mount currently owns them.
  # Writes *data* to the listener, with an ICY metadata block every `metadata_interval` bytes when
  # the player asked for metadata, then flushes once, so the audio and its metadata leave together.
  private def send_stream(listener : Listener, data : Bytes)
    return if data.empty?
    owner = listener.owner
    io = listener.io

    if listener.wants_metadata?
      offset = 0
      while offset < data.size
        length = Math.min(listener.remaining, data.size - offset)
        io.write(data[offset, length])
        offset += length
        listener.remaining -= length

        if listener.remaining == 0
          io.write(owner.metadata_block(listener))
          listener.remaining = listener.metadata_interval
        end
      end
    else
      io.write(data)
    end
    io.flush
    owner.count_bytes_sent(data.size)
    listener.count_bytes(data.size)
  end

  private def write_listener(listener : Listener, intro : Bytes, burst : Bytes)
    send_stream(listener, intro)
    send_stream(listener, burst)
    while data = listener.queue.receive?
      send_stream(listener, data)
    end
  rescue IO::Error | Channel::ClosedError
  ensure
    listener.owner.remove_listener(listener.io)
    listener.close
  end

  protected def count_bytes_sent(size : Int32)
    @bytes_sent.add(size.to_u64, :relaxed)
  end

  private def append_to_buffer(data : Bytes)
    @buffer_mutex.synchronize do
      capacity = @buffer.size
      if data.size >= capacity
        data[data.size - capacity, capacity].copy_to(@buffer)
        @buffer_start = 0
        @buffer_size = capacity
        return
      end

      overflow = Math.max(@buffer_size + data.size - capacity, 0)
      @buffer_start = (@buffer_start + overflow) % capacity
      @buffer_size -= overflow
      write_at = (@buffer_start + @buffer_size) % capacity
      first = Math.min(data.size, capacity - write_at)
      data[0, first].copy_to(@buffer[write_at, first])
      data[first, data.size - first].copy_to(@buffer[0, data.size - first]) if first < data.size
      @buffer_size += data.size
    end
  end

  private def buffered_audio : Bytes
    @buffer_mutex.synchronize do
      result = Bytes.new(@buffer_size)
      first = Math.min(@buffer_size, @buffer.size - @buffer_start)
      @buffer[@buffer_start, first].copy_to(result[0, first])
      @buffer[0, @buffer_size - first].copy_to(result[first, @buffer_size - first]) if first < @buffer_size
      result
    end
  end

  private def synchronize_audio(data : Bytes) : Bytes
    return synchronize_frames(data, 4) { |bytes| parse_mp3_frame(bytes) } if mp3?
    return synchronize_frames(data, AAC::SYNC_PROBE_SIZE) { |bytes| AAC.parse_header(bytes) } if aac?
    data
  end

  private def parse_mp3_frame(data : Bytes) : MP3::Frame?
    return unless frame = MP3.parse_frame(data, free_format_bytes: @mp3_free_format_bytes)
    if free_format_bytes = frame.free_format_bytes
      @mp3_free_format_bytes = free_format_bytes if free_format_bytes.positive?
    else
      @mp3_free_format_bytes = nil
    end
    frame
  end

  private def synchronize_frames(data : Bytes, minimum_header_size : Int32, & : Bytes -> T?) : Bytes forall T
    @frame_pending.write(data)
    bytes = @frame_pending.to_slice
    @frame_output.clear
    offset = 0
    candidate_offset = nil.as(Int32?)

    while offset + minimum_header_size <= bytes.size
      frame = yield bytes[offset..]
      unless frame
        @frame_synced = false
        offset += 1
        next
      end
      size = frame.frame_size
      unless size.positive?
        candidate_offset ||= offset
        offset += 1
        next
      end
      if offset + size > bytes.size
        break if @frame_synced
        candidate_offset ||= offset
        offset += 1
        next
      end

      unless @frame_synced
        next_offset = offset + size
        if next_offset + minimum_header_size > bytes.size
          candidate_offset ||= offset
          offset += 1
          next
        end
        next_frame = yield bytes[next_offset..]
        unless next_frame && frame.compatible?(next_frame)
          offset += 1
          next
        end
        @frame_synced = true
      end

      @frame_output.write(bytes[offset, size])
      offset += size
    end

    pending_offset = @frame_synced ? offset : candidate_offset || offset
    pending = bytes[pending_offset, bytes.size - pending_offset].dup
    @frame_pending.clear
    @frame_pending.write(pending)
    @frame_output.to_slice
  end

  private def reset_frame_sync
    @broadcast_mutex.synchronize do
      @frame_pending.clear
      @frame_synced = false
      @mp3_free_format_bytes = nil
      @join = new_join
    end
  end

  private def media_type : String
    @station_mutex.synchronize { @media_type }
  end

  private def mp3? : Bool
    media_type.in?("audio/mpeg", "audio/mp3")
  end

  protected def stream_format : String
    return "mp3" if mp3?
    return "aac" if aac?
    return "ogg" if ogg?
    return "flac" if flac?
    return "webm" if media_type.ends_with?("/webm")
    return "matroska" if matroska?
    media_type
  end

  # Native FLAC; FLAC in Ogg is "ogg".
  private def flac? : Bool
    media_type.in?("audio/flac", "audio/x-flac")
  end

  private def matroska? : Bool
    media_type.in?("audio/webm", "video/webm", "audio/x-matroska", "video/x-matroska", "audio/matroska", "video/matroska")
  end

  private def aac? : Bool
    media_type.in?("audio/aac", "audio/aacp")
  end

  private def ogg? : Bool
    type = media_type
    type.includes?("ogg") || type.starts_with?("audio/opus")
  end

  private def align_mp3(audio : Bytes) : Bytes
    return Bytes.empty unless located = MP3.find_frame(audio, require_complete: true, free_format_bytes: @mp3_free_format_bytes)
    audio[located.offset..]
  end

  private def align_aac(audio : Bytes) : Bytes
    return Bytes.empty unless located = AAC.find_frame(audio, require_complete: true)
    audio[located.offset..]
  end

  private def capture_mp3_info(data : Bytes)
    return unless frame = MP3.parse_frame(data, free_format_bytes: @mp3_free_format_bytes)
    @mp3_info = frame
    @bitrate.set(frame.bitrate_kbps, :relaxed)
  end

  private def capture_ogg_headers(data : Bytes)
    @ogg_sync.each_page(data) do |_offset, header, body|
      reset_ogg_headers if @ogg_data_started && ogg_bos?(header)
      serial = ogg_serial(header)
      stream = @ogg_streams.put_if_absent(serial) { OggLogicalStream.new }
      header_page = !stream.headers_complete?
      if header_page
        @ogg_headers.write(header)
        @ogg_headers.write(body)
        stream.last_header_sequence = ogg_sequence(header)
        inspect_ogg_packets(header, body, stream)
      else
        @ogg_data_started = true
      end
      stream.eos = true if ogg_eos?(header)
      stream.headers_complete = true if stream.eos?
    end

    if @ogg_headers.size >= 131_072
      @ogg_headers.clear
      @ogg_streams.each_value(&.headers_complete=(true))
      @ogg_data_started = true
    end
  end

  private def inspect_ogg_packets(header : Bytes, body : Bytes, stream : OggLogicalStream)
    segments = header[26].to_i
    body_offset = 0

    segments.times do |index|
      length = header[27 + index].to_i
      stream.packet.write(body[body_offset, length])
      body_offset += length
      next if length == 255

      packet = stream.packet.to_slice
      if stream.header_packets == 0
        stream.expected_headers = ogg_header_count(packet)
      end
      stream.header_packets += 1
      if stream.expected_headers == OGG_FLAC_UNTIL_LAST
        # Ogg FLAC that doesn't say how many header packets follow: they end with the metadata block
        # marked last (the first packet's STREAMINFO, or the first byte of a later packet).
        flags = stream.header_packets == 1 ? packet[13]? : packet[0]?
        stream.headers_complete = true if flags.try { |byte| byte & 0x80 != 0 }
      end
      stream.packet.clear
      if stream.expected_headers.positive? && stream.header_packets >= stream.expected_headers
        stream.headers_complete = true
      end
    end
  end

  # Ogg FLAC header packets: the first one, then as many as it says, or (when it says 0) up to the
  # last metadata block.
  OGG_FLAC_UNTIL_LAST = -1

  private def ogg_header_count(packet : Bytes) : Int32
    if bytes_start_with?(packet, "\x7FFLAC") && packet.size >= 9
      count = IO::ByteFormat::BigEndian.decode(UInt16, packet[7, 2]).to_i
      return count.positive? ? count + 1 : OGG_FLAC_UNTIL_LAST
    end
    return 2 if bytes_start_with?(packet, "OpusHead")
    return 3 if packet.size >= 7 && {0x01_u8, 0x80_u8}.includes?(packet[0]) && bytes_start_with?(packet[1..], packet[0] == 0x01 ? "vorbis" : "theora")
    return 2 if bytes_start_with?(packet, "Speex   ")
    return 0 if bytes_start_with?(packet, "fishead\0")
    1
  end

  private def ogg_burst(audio : Bytes) : Bytes
    headers = @ogg_headers.to_slice
    return audio if headers.empty?
    return audio if audio.size >= headers.size && audio[0, headers.size] == headers

    offset = find_resumable_ogg_page(audio)
    tail = offset ? audio[offset..] : Bytes.empty
    result = Bytes.new(headers.size + tail.size)
    headers.copy_to(result[0, headers.size])
    tail.copy_to(result[headers.size, tail.size])
    result
  end

  private def find_resumable_ogg_page(audio : Bytes) : Int32?
    pages = ogg_pages(audio)
    required = @ogg_streams.compact_map do |serial, stream|
      serial if stream.headers_complete? && !stream.eos?
    end
    return if pages.empty? || required.empty?

    # ponytail: O(n²) over the bounded burst buffer; index per serial if buffers grow beyond kilobytes.
    pages.each_with_index do |candidate, index|
      next unless required.includes?(candidate.serial)
      next if ogg_bos?(candidate.header_type) || ogg_continued?(candidate.header_type)
      next unless candidate.sequence > @ogg_streams[candidate.serial].last_header_sequence

      safe = required.all? do |serial|
        first = pages.each.skip(index).find do |page|
          page.serial == serial && page.sequence > @ogg_streams[serial].last_header_sequence
        end
        first && !ogg_bos?(first.header_type) && !ogg_continued?(first.header_type)
      end
      return candidate.offset if safe
    end
    nil
  end

  private def reset_ogg_headers
    @ogg_headers.clear
    @ogg_streams.clear
    @ogg_data_started = false
  end

  private def ogg_pages(bytes : Bytes) : Array(OggPage)
    pages = [] of OggPage
    sync = Ogg::Sync.new
    begin
      sync.each_page(bytes) do |offset, header, _body|
        pages << OggPage.new(offset.to_i, ogg_serial(header), ogg_sequence(header), header[5])
      end
    ensure
      sync.close
    end
    pages
  end

  private def ogg_sequence(page : Bytes) : UInt32
    IO::ByteFormat::LittleEndian.decode(UInt32, page[18, 4])
  end

  private def ogg_serial(page : Bytes) : UInt32
    IO::ByteFormat::LittleEndian.decode(UInt32, page[14, 4])
  end

  private def ogg_bos?(page : Bytes) : Bool
    ogg_bos?(page[5])
  end

  private def ogg_bos?(header_type : UInt8) : Bool
    (header_type & 0x02) != 0
  end

  private def ogg_eos?(page : Bytes) : Bool
    (page[5] & 0x04) != 0
  end

  private def ogg_continued?(header_type : UInt8) : Bool
    (header_type & 0x01) != 0
  end

  private def bytes_start_with?(bytes : Bytes, prefix : String) : Bool
    prefix.bytesize <= bytes.size && bytes[0, prefix.bytesize] == prefix.to_slice
  end

  private def build_metadata_block(song : String) : Bytes
    return EMPTY_METADATA_BLOCK if song.empty?

    text = String.build(song.bytesize + 32) do |io|
      io << "StreamTitle='"
      song.each_byte do |byte|
        io.write_byte(0x5c_u8) if byte.in?(0x27_u8, 0x5c_u8)
        io.write_byte(byte)
      end
      io << "';StreamUrl='';"
    end
    payload = text.to_slice[0, Math.min(text.bytesize, 4080)]
    blocks = (payload.size + 15) // 16
    result = Bytes.new(1 + blocks * 16, 0_u8)
    result[0] = blocks.to_u8
    payload.copy_to(result[1, payload.size])
    result
  end

  protected def metadata_block(listener : Listener) : Bytes
    @metadata_mutex.synchronize do
      if listener.metadata_version == @metadata_version
        EMPTY_METADATA_BLOCK
      else
        listener.metadata_version = @metadata_version
        @metadata_block
      end
    end
  end
end
