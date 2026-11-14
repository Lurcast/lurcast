require "../hls"
require "../recording"

class IcecastServer
  # Where `reload_config` reads the configuration from; set by the command-line runner.
  property config_path : String?

  record ReloadResult, ok : Bool, error : String? = nil, restart_required : Array(String) = [] of String do
    include JSON::Serializable
  end

  # Feeds a mount's audio to its HLS segmenter, with the song playing at that moment.
  private class HLSTap < AudioTap
    getter segmenter : HLS::Segmenter

    def initialize(@segmenter : HLS::Segmenter, @mount : MountPoint)
    end

    def receive(data : Bytes) : Nil
      @segmenter.write(data, @mount.current_song)
    end
  end

  record RecordingFile, name : String, bytes : Int64, modified_at : Time, recording : Bool do
    include JSON::Serializable
  end

  record RecordingList, files : Array(RecordingFile) do
    include JSON::Serializable
  end

  private class AccessState
    property status = 0
    property bytes = 0_i64

    getter started_at = Time.utc
    getter started = Time.instant
  end

  @access_states = {} of IO => AccessState
  @access_mutex = Mutex.new
  @recordings = {} of String => Recording
  @recordings_mutex = Mutex.new
  @hls_taps = {} of String => HLSTap
  @hls_clients = {} of String => Hash(String, Time::Instant)
  @hls_mutex = Mutex.new
  @hls_pruned_at = Time.instant
  @tls_context : OpenSSL::SSL::Context::Server?
  @trusted_proxies = TrustedProxies.new([] of String)
  @reload_mutex = Mutex.new

  private def setup_features
    setup_bans_and_history
    @trusted_proxies = TrustedProxies.new(@config.trusted_proxies)
  end

  private def stop_features
    @history.save
    @recordings_mutex.synchronize { @recordings.values.tap { @recordings.clear } }.each(&.stop)
  end

  # ---------- Configuration reload ----------

  # Reads the configuration file again and applies it without dropping connections. If the file is
  # invalid, the running configuration stays. Ports, `host`, and master relay settings need a restart.
  def reload_config : ReloadResult
    @reload_mutex.synchronize do
      path = @config_path || return ReloadResult.new(false, "the server was not started from a configuration file")
      begin
        fresh = Config.load(path)
      rescue ex
        Log.error { "Configuration reload failed; keeping the running configuration: #{ex.message}" }
        return ReloadResult.new(false, ex.message || "invalid configuration")
      end

      old_relays = @config.relays
      restart = @config.reload_from(fresh)
      Log.setup(@config.log_level)
      reload_tls
      reload_relays(old_relays)
      reload_features
      @extensions.each do |extension|
        extension.config_reloaded(@config)
      rescue ex
        Log.error(exception: ex) { "Extension failed to apply the reloaded configuration" }
      end
      Log.info { "Configuration reloaded from #{path}" }
      Log.warn { "Restart to apply: #{restart.join(", ")}" } unless restart.empty?
      notify_extensions("apply the reloaded configuration", &.reload_finished(restart))
      ReloadResult.new(true, restart_required: restart)
    end
  end

  private def reload_features
    @trusted_proxies = TrustedProxies.new(@config.trusted_proxies)
    @bans.load
    streams.each do |stream|
      next if !stream.has_source? || stream.source_protocol.file?
      start_recording(stream) if @config.record?(stream.mount)
      @config.hls_for?(stream.mount) ? start_hls(stream) : stop_hls(stream.mount)
    end
  end

  private def reload_tls
    return unless @tls_context
    cert = @config.tls_cert
    key = @config.tls_key
    return unless cert && key
    @tls_context = build_tls_context(cert, key)
  rescue ex
    Log.error { "Could not reload the TLS certificate; keeping the old one: #{ex.message}" }
  end

  private def build_tls_context(cert : String, key : String) : OpenSSL::SSL::Context::Server
    context = OpenSSL::SSL::Context::Server.new
    context.certificate_chain = cert
    context.private_key = key
    context
  end

  private def reload_relays(old_relays : Array(RelayConfig))
    key = ->(relay : RelayConfig) { {relay.url, relay.mount, relay.username, relay.password, relay.retry_delay, relay.on_demand?} }
    wanted = @config.relays.to_h { |relay| {key.call(relay), relay} }
    previous = old_relays.map { |relay| key.call(relay) }.to_set
    stale = @relays_mutex.synchronize do
      removed = @relays.reject { |mount, relay| @master_relays.includes?(mount) || wanted.has_key?(key.call(relay)) }
      removed.keys.compact_map do |mount|
        @relays.delete(mount)
        @relay_demand.delete(mount)
        @relay_sources.delete(mount)
      end
    end
    stale.each { |source| source.close rescue nil }
    wanted.each { |relay_key, relay| register_relay(relay) unless previous.includes?(relay_key) && relay_active?(relay.mount) }
  end

  private def relay_active?(mount : String) : Bool
    @relays_mutex.synchronize { @relays.has_key?(mount) }
  end

  # ---------- Request logs ----------

  # Whether an extension wants `request_finished` for each request.
  private def request_logging? : Bool
    @extensions.any?(&.logs_requests?)
  end

  private def begin_access(client : IO)
    return unless request_logging?
    @access_mutex.synchronize { @access_states[client] = AccessState.new }
  end

  # Remembers the status and size of the response written to *client*, for request logs.
  private def note_response(client : IO, status : Int32, bytes : Int64)
    return unless request_logging?
    @access_mutex.synchronize do
      if state = @access_states[client]?
        state.status = status
        state.bytes = bytes
      end
    end
  end

  private def finish_access(client : IO, request : HTTP::Request, address : String)
    state = @access_mutex.synchronize { @access_states.delete(client) }
    return unless state
    headers = request.headers
    record = Lurcast::RequestRecord.new(
      address: client_address(headers, address),
      user: basic_credentials(headers).try(&.[0]),
      started_at: state.started_at,
      method: request.method,
      target: request.resource,
      version: request.version,
      status: state.status,
      bytes: state.bytes,
      referer: headers["Referer"]?,
      user_agent: headers["User-Agent"]?,
      duration: Time.instant - state.started,
    )
    notify_extensions("log a request") { |extension| extension.request_finished(record) if extension.logs_requests? }
  end

  private def source_connected(mount : String, point : MountPoint)
    return if point.source_protocol.file?
    start_recording(point) if @config.record?(mount)
    start_hls(point) if @config.hls_for?(mount)
  end

  private def source_disconnected(mount : String, point : MountPoint)
    return if point.source_protocol.file?
    stop_recording(mount)
    stop_hls(mount)
  end

  # ---------- Listener locations ----------

  # The listener's address, taken from X-Forwarded-For when the connection comes from a trusted proxy.
  private def client_address(headers : HTTP::Headers, socket_address : String) : String
    @trusted_proxies.client_address(socket_address, headers["X-Forwarded-For"]?)
  end

  private def listener_country(address : String) : String?
    @extensions.each do |extension|
      country = extension.listener_country(address)
      return country if country
    rescue ex
      Log.error(exception: ex) { "Extension failed to look up a listener location" }
    end
    nil
  end

  private def locations_source : String?
    @extensions.each do |extension|
      source = extension.locations_source
      return source if source
    end
    nil
  end

  # ---------- Recording ----------

  def recording_for(mount : String) : Recording?
    @recordings_mutex.synchronize { @recordings[mount]? }
  end

  # Starts recording *point* unless it already is. Returns the recording, or nil when recording is off.
  private def start_recording(point : MountPoint, manual = false) : Recording?
    directory = @config.recordings_dir
    return unless directory
    split = @config.record_split_minutes
    splittable = point.format.in?("mp3", "aac")
    recording = @recordings_mutex.synchronize do
      next if @recordings.has_key?(point.mount)
      @recordings[point.mount] = Recording.new(point.mount, directory, Recording.extension_for(point.content_type),
        split.positive? && splittable ? split.minutes : nil, manual) do |file|
        Log.info { "Recorded #{file.path} (#{file.bytes} bytes)" }
        notify_extensions("record a finished recording", &.recording_finished(file))
      end
    end
    point.add_tap(recording, burst: true) if recording
    recording || recording_for(point.mount)
  end

  private def stop_recording(mount : String) : Bool
    recording = @recordings_mutex.synchronize { @recordings.delete(mount) }
    return false unless recording
    get_mount(mount).try(&.remove_tap(recording))
    recording.stop
    true
  end

  private def recordings_directory(mount : String) : String?
    @config.recordings_dir.try { |dir| File.join(dir, Recording.slug(mount)) }
  end

  # ---------- HLS ----------

  private def start_hls(point : MountPoint)
    codec = case point.format
            when "mp3" then HLS::Codec::MP3
            when "aac" then point.adts? ? HLS::Codec::AAC : nil
            end
    return unless codec
    return unless @extensions.all?(&.hls_allowed?(point.mount))
    tap = @hls_mutex.synchronize do
      next if @hls_taps.has_key?(point.mount)
      segmenter = HLS::Segmenter.new(codec, @config.hls_segment_seconds.to_f, @config.hls_window)
      @hls_taps[point.mount] = HLSTap.new(segmenter, point)
    end
    point.add_tap(tap) if tap
  end

  private def stop_hls(mount : String)
    tap = @hls_mutex.synchronize do
      @hls_clients.delete(mount)
      @hls_taps.delete(mount)
    end
    get_mount(mount).try(&.remove_tap(tap)) if tap
  end

  private def hls_segmenter(mount : String) : HLS::Segmenter?
    @hls_mutex.synchronize { @hls_taps[mount]?.try(&.segmenter) }
  end

  # Listeners using HLS, counted as addresses that fetched a segment in the last few segment lengths.
  private def hls_listener_count(mount : String) : Int32
    window = (@config.hls_segment_seconds * 3).seconds
    now = Time.instant
    @hls_mutex.synchronize do
      clients = @hls_clients[mount]?
      next 0 unless clients
      clients.reject! { |_address, seen| now - seen > window }
      clients.size
    end
  end

  # Remembers that *address* fetched a segment. Old entries are dropped every so often, so the table
  # stays small even when nobody opens the dashboard.
  private def record_hls_client(mount : String, address : String)
    now = Time.instant
    window = (@config.hls_segment_seconds * 3).seconds
    @hls_mutex.synchronize do
      (@hls_clients[mount] ||= {} of String => Time::Instant)[address] = now
      if now - @hls_pruned_at > window
        @hls_pruned_at = now
        @hls_clients.each_value(&.reject! { |_address, seen| now - seen > window })
      end
    end
  end

  private def handle_hls_playlist(client : IO, mount : String, address : String, headers : HTTP::Headers, head : Bool)
    client_ip = client_address(headers, address)
    return send_banned(client, head) if listener_ban(client_ip, headers, mount)
    if realm = listener_challenge(Lurcast::ListenerRequest.new(nil, mount, client_ip, headers))
      return request_authentication(client, realm)
    end
    segmenter = hls_segmenter(mount)
    playlist = segmenter.try(&.playlist("#{WebAssets::PREFIX}/hls#{mount}/"))
    unless playlist
      send_response(client, 404, segmenter ? "Stream is starting; try again in a few seconds" : "HLS is not available for this mount", head: head)
      return
    end
    response_headers = cors_headers(headers) || HTTP::Headers.new
    response_headers["Cache-Control"] = "no-cache"
    send_response(client, 200, playlist, "application/vnd.apple.mpegurl", response_headers, head: head)
  end

  private def handle_hls_segment(client : IO, rest : String, address : String, headers : HTTP::Headers, head : Bool)
    slash = rest.rindex('/')
    file = slash ? rest[slash + 1..] : ""
    mount = slash ? rest[0, slash] : ""
    sequence = file.split('.', 2).first.to_i64?
    segmenter = hls_segmenter(mount) if valid_mount?(mount)
    segment = segmenter.try { |hls| sequence.try { |seq| hls.segment(seq) } }
    unless segmenter && segment
      send_response(client, 404, "Segment not found", head: head)
      return
    end
    client_ip = client_address(headers, address)
    return send_banned(client, head) if listener_ban(client_ip, headers, mount)
    if realm = listener_challenge(Lurcast::ListenerRequest.new(nil, mount, client_ip, headers))
      return request_authentication(client, realm)
    end
    record_hls_client(mount, address)
    response_headers = cors_headers(headers) || HTTP::Headers.new
    response_headers["Cache-Control"] = "public, max-age=#{@config.hls_segment_seconds * @config.hls_window}"
    send_binary(client, segment, segmenter.content_type, response_headers, head)
  end

  private def send_binary(client : IO, body : Bytes, content_type : String, headers : HTTP::Headers, head : Bool)
    write_response(client, 200, body, content_type, headers, head)
  end

  # ---------- Admin endpoints ----------

  private def handle_reload(client : IO, headers : HTTP::Headers)
    access = require_admin(client, headers) || return
    unless access.full?
      send_response(client, 403, "Only the server admin can reload the configuration")
      return
    end
    result = reload_config
    send_response(client, result.ok ? 200 : 400, result.to_json, "application/json", HTTP::Headers{"Cache-Control" => "no-store"})
  end

  private def handle_record(client : IO, params : HTTP::Params, headers : HTTP::Headers)
    access = require_admin(client, headers) || return
    unless @config.recordings_dir
      send_response(client, 409, "Set recordings_dir in the configuration to record")
      return
    end
    mount = params["mount"]?.try { |value| canonical_mount(value) }
    point = mount.try { |name| get_mount(name) if access.allows?(name) }
    unless mount && point && point.has_source?
      send_response(client, 404, "Stream not found")
      return
    end
    case params["action"]?
    when "start"
      already = recording_for(mount)
      start_recording(point, manual: true)
      send_response(client, 200, already ? "Already recording" : "Recording started")
    when "stop"
      stopped = stop_recording(mount)
      send_response(client, stopped ? 200 : 404, stopped ? "Recording stopped" : "Not recording")
    else
      send_response(client, 400, "action must be start or stop")
    end
  end

  # Lists the finished and current recording files of a mount, newest first.
  private def handle_recordings_list(client : IO, params : HTTP::Params, headers : HTTP::Headers, head : Bool)
    access = require_admin(client, headers) || return
    mount = params["mount"]?.try { |value| canonical_mount(value) }.try { |name| name if access.allows?(name) }
    directory = mount.try { |name| recordings_directory(name) }
    current = mount.try { |name| recording_for(name).try(&.current_path) }
    files = [] of RecordingFile
    if directory && Dir.exists?(directory)
      Dir.each_child(directory) do |name|
        path = File.join(directory, name)
        info = File.info?(path, follow_symlinks: false)
        next unless info && info.file?
        files << RecordingFile.new(name, info.size, info.modification_time, path == current)
      end
    end
    files.sort_by!(&.name).reverse!
    response_headers = HTTP::Headers{"Cache-Control" => "no-store"}
    send_response(client, 200, RecordingList.new(files).to_json, "application/json", response_headers, head: head)
  end

  private def handle_recording_download(client : IO, path : String, headers : HTTP::Headers, head : Bool)
    access = require_admin(client, headers) || return
    root = @config.recordings_dir
    parts = path.lchop("/admin/recordings/").split('/')
    valid = parts.size == 2 && parts.all? { |part| part.matches?(/\A[A-Za-z0-9._-]+\z/) && !part.matches?(/\A\.+\z/) }
    valid &&= access.full? || !!access.mounts.try(&.any? { |mount| Recording.slug(mount) == parts[0] })
    file_path = File.join(root, parts[0], parts[1]) if root && valid
    info = file_path.try { |file| File.info?(file, follow_symlinks: false) }
    unless file_path && info && info.file?
      send_response(client, 404, "Recording not found", head: head)
      return
    end
    download_headers = HTTP::Headers{
      "Content-Disposition"    => %(attachment; filename="#{parts[1]}"),
      "Cache-Control"          => "no-store",
      "X-Content-Type-Options" => "nosniff",
    }
    client.write(response_head(200, recording_content_type(file_path), info.size, download_headers).to_slice)
    File.open(file_path) { |file| IO.copy(file, client) } unless head
    client.flush
    note_response(client, 200, head ? 0_i64 : info.size)
  rescue IO::Error
  end

  private def recording_content_type(path : String) : String
    case File.extname(path)
    when ".mp3"          then "audio/mpeg"
    when ".aac"          then "audio/aac"
    when ".ogg", ".opus" then "audio/ogg"
    when ".flac"         then "audio/flac"
    else                      "application/octet-stream"
    end
  end
end
