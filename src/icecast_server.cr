require "base64"
require "http/client"
require "http/headers"
require "http/params"
require "http/request"
require "http/status"
require "json"
require "log"
require "mime"
require "openssl"
require "socket"
require "./admin_api"
require "./config"
require "./extension"
require "./icecast_api"
require "./icecast_xml"
require "./mount_point"
require "./pacer"
require "./radio_api"
require "./shoutcast_api"
require "./templates"
require "./ultravox"
require "./web_assets"

class IcecastServer
  SERVER_ID       = "Lurcast/0.3.0"
  ALLOWED_METHODS = "GET, HEAD, PUT, SOURCE, POST, PATCH, OPTIONS"
  MAX_INTRO_BYTES = 16 * 1024 * 1024
  MUTATING_PATHS  = {"/admin/metadata", "/admin.cgi", "/admin/killsource", "/admin/fallbacks", "/admin/killclient", "/admin/moveclients", "/admin/record", "/admin/reload"}

  getter config : Config
  getter start_time : Time = Time.utc

  @streams = {} of String => MountPoint
  @streams_mutex = Mutex.new
  @connections = Hash(String, Int32).new(0)
  @listener_addresses = Hash(String, Int32).new(0)
  @requests = {} of String => Array(Time::Instant)
  @last_request_prune : Time::Instant? = nil
  @active_listeners = 0
  @pending_listeners = Hash(UInt64, Int32).new(0)
  @limits_mutex = Mutex.new
  @servers = Set(TCPServer).new
  @servers_mutex = Mutex.new
  @services_started = Atomic(Bool).new(false)
  @next_listener_id = Atomic(Int64).new(0_i64)
  @relays = {} of String => RelayConfig
  @relay_demand = Hash(String, Int32).new(0)
  @relay_sources = {} of String => IO
  @master_relays = Set(String).new
  @relays_mutex = Mutex.new
  @running = Atomic(Bool).new(false)
  getter extensions = [] of Lurcast::Extension

  private enum ListenerReservation
    Reserved
    GlobalFull
    MountFull
  end

  def initialize(@config : Config)
    setup_features
    Lurcast::Plugins.build(@config).each { |plugin| add_extension(plugin) }
  end

  def start
    @running.set(true)
    if port = @config.tls_port
      tls_cert = @config.tls_cert || raise ArgumentError.new("TLS certificate is required")
      tls_key = @config.tls_key || raise ArgumentError.new("TLS key is required")
      spawn serve_tls(TCPServer.new(@config.host, port), build_tls_context(tls_cert, tls_key)), name: "tls accept"
    end
    if port = @config.shoutcast_port
      spawn serve_shoutcast(TCPServer.new(@config.host, port)), name: "shoutcast accept"
    end
    serve(TCPServer.new(@config.host, @config.port))
  end

  def serve(listener : TCPServer)
    accept_connections(listener, "Listening", start_services: true) do |client, address|
      handle_client(client, address)
    end
  ensure
    @running.set(false)
  end

  def serve_tls(listener : TCPServer, context : OpenSSL::SSL::Context::Server)
    @tls_context = context
    accept_connections(listener, "TLS listening") do |client, address|
      tls = OpenSSL::SSL::Socket::Server.new(client, @tls_context || context, sync_close: true)
      handle_client(tls, address)
    rescue ex
      Log.debug { "TLS connection from #{address} failed: #{ex.message}" }
      client.close rescue nil
    end
  end

  def serve_shoutcast(listener : TCPServer)
    accept_connections(listener, "SHOUTcast source listening") do |client, address|
      handle_shoutcast_source(client, address)
    end
  end

  private def accept_connections(listener : TCPServer, log_message : String, start_services = false, &handler : TCPSocket, String ->)
    @servers_mutex.synchronize { @servers.add(listener) }
    @running.set(true)
    start_background_services if start_services
    Log.info { "#{log_message} on #{listener.local_address}" }

    while running? && (client = listener.accept?)
      configure_socket(client)
      address = remote_address(client)
      spawn handler.call(client, address), name: "connection"
    end
  rescue ex : IO::Error
    raise ex if running?
  end

  # Registers an extension; call before `start` or `serve`.
  def add_extension(extension : Lurcast::Extension)
    @extensions << extension
  end

  def stop
    @running.set(false)
    @extensions.each(&.stop)
    stop_features
    @servers_mutex.synchronize { @servers.each { |server| server.close rescue nil } }
    streams.each(&.disconnect)
  end

  def streams : Array(MountPoint)
    @streams_mutex.synchronize { @streams.values }
  end

  def get_mount(mount : String) : MountPoint?
    @streams_mutex.synchronize { @streams[mount]? }
  end

  # The per-address connection slot a request holds. A listener hands it back once its stream
  # starts, so long-lived listeners count against `max_listeners_per_ip` instead.
  private class ConnectionSlot
    property? held = true
  end

  private def handle_client(client : IO, address : String)
    slot = ConnectionSlot.new
    accepted = begin_request(address)
    unless accepted
      send_response(client, 429, "Too many connections or requests")
      return
    end

    request = HTTP::Request.from_io(client)
    case request
    when Nil
      return
    when HTTP::Status
      send_response(client, request.code, request.description || "Bad request")
      return
    end
    set_read_timeout(client, @config.timeout)

    method = request.method
    headers = request.headers
    begin_access(client)
    if mutating_request?(method, request.path) && cross_site_form?(headers, request.query_params)
      send_response(client, 403, "Cross-site admin requests are not allowed")
      return
    end
    return if @extensions.any?(&.handle_request(self, client, request, address))

    case method
    when "PUT", "SOURCE"
      if mount = canonical_mount(request.path)
        handle_source(client, request.body, mount, headers, address, method)
      else
        send_response(client, 400, "Invalid mount point")
      end
    when "GET", "HEAD"
      handle_get(client, request, address, slot, head: method == "HEAD")
    when "POST"
      handle_post(client, request, address)
    when "PATCH"
      handle_patch(client, request, address)
    when "OPTIONS"
      response_headers = cors_headers(headers) || HTTP::Headers.new
      response_headers["Allow"] = ALLOWED_METHODS
      response_headers["Access-Control-Allow-Methods"] = ALLOWED_METHODS
      response_headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type, Icy-MetaData"
      send_response(client, 204, "", extra_headers: response_headers)
    else
      send_response(client, 405, "Method not allowed", extra_headers: HTTP::Headers{"Allow" => ALLOWED_METHODS})
    end
  rescue ex : ArgumentError
    send_response(client, 400, ex.message || "Bad request") unless client.closed?
  rescue IO::TimeoutError
    Log.debug { "Connection from #{address} timed out" }
  rescue ex : IO::Error
    Log.debug { "Connection from #{address} closed: #{ex.message}" }
  rescue ex
    Log.error(exception: ex) { "Connection from #{address} failed" }
    send_response(client, 500, "Internal server error") unless client.closed?
  ensure
    finish_access(client, request, address) if request.is_a?(HTTP::Request)
    end_request(address) if accepted && slot.try(&.held?)
    client.close unless client.closed?
  end

  private def handle_get(client : IO, request : HTTP::Request, address : String, slot : ConnectionSlot, head = false)
    path = request.path
    headers = request.headers
    if head && path.in?(MUTATING_PATHS)
      send_response(client, 405, "Method not allowed", extra_headers: HTTP::Headers{"Allow" => "GET, POST"}, head: true)
      return
    end

    case path
    when "/", "/status.xsl", "/status.html", "/index.html"
      send_page(client, Templates.index(public_streams), PUBLIC_PAGE_CSP, head)
    when "/admin/", "/admin/index.html"
      handle_admin_page(client, head)
    when "/admin/api/overview"
      handle_admin_overview(client, request.query_params, headers, head)
    when "/admin/api/bans"
      handle_bans_list(client, request.query_params, headers, head)
    when "/admin/api/history"
      handle_history(client, request.query_params, headers, head)
    when "/admin/api/recordings"
      handle_recordings_list(client, request.query_params, headers, head)
    when "/status-json.xsl", "/status.json"
      send_json(client, status_json(public_streams), headers, head: head)
    when "/api/v1/stations"
      body = RadioAPI.render(SERVER_ID, @config.public_url, @start_time, public_streams, ->mount_fields(String, Lurcast::MountView))
      send_json(client, body, headers, head: head)
    when "/admin"
      if headers["Accept"]?.try(&.includes?("text/html"))
        send_response(client, 302, "", extra_headers: HTTP::Headers{"Location" => "/admin/"}, head: head)
        return
      end
      return request_authentication(client, "Lurcast Admin") unless authenticate(headers, "admin", @config.admin_password)
      send_json(client, status_json(streams), headers, head: head)
    when "/admin/stats.json", "/admin/listeners"
      return request_authentication(client, "Lurcast Admin") unless authenticate(headers, "admin", @config.admin_password)
      body = path == "/admin/listeners" ? listeners_json : status_json(streams)
      send_json(client, body, headers, head: head)
    when "/admin/stats", "/admin/stats.xml", "/admin/listmounts", "/admin/listclients"
      handle_admin_xml(client, path, request.query_params, headers, head)
    when "/admin/killclient"
      handle_kill_client(client, request.query_params, headers)
    when "/admin/moveclients"
      handle_move_clients(client, request.query_params, headers)
    when "/7.html", "/stats", "/statistics", "/currentsong", "/played", "/played.html"
      handle_shoutcast_stats(client, path, request.query_params, headers, head)
    when "/admin/streamlist.txt"
      return request_authentication(client, "Lurcast Relay") unless authenticate(headers, @config.relay_username, @config.relay_password)
      body = streams.compact_map { |stream| stream.mount if stream.has_source? }.sort!.join('\n')
      body += '\n' unless body.empty?
      send_response(client, 200, body, "text/plain; charset=utf-8", head: head)
    when "/admin/metadata"
      handle_metadata(client, request.query_params, headers, address)
    when "/admin.cgi"
      handle_shoutcast_admin(client, request.query_params, headers)
    when "/admin/killsource"
      handle_kill_source(client, request.query_params, headers)
    when "/admin/fallbacks"
      handle_set_fallback(client, request.query_params, headers)
    else
      if path.starts_with?("#{WebAssets::PREFIX}/")
        handle_asset(client, path.lchop("#{WebAssets::PREFIX}/"), request.query_params, headers, head)
      elsif path.starts_with?("/admin/recordings/")
        handle_recording_download(client, path, headers, head)
      elsif path.ends_with?(".m3u")
        handle_playlist(client, path.rchop(".m3u"), headers, head)
      elsif mount = canonical_mount(path)
        handle_listener(client, mount, headers, address, slot, head)
      else
        send_response(client, 404, "Not found")
      end
    end
  end

  private def handle_post(client : IO, request : HTTP::Request, address : String)
    headers = request.headers
    case request.path
    when "/admin/metadata"
      handle_metadata(client, request.query_params, headers, address)
    when "/admin/killsource"
      handle_kill_source(client, request.query_params, headers)
    when "/admin/fallbacks"
      handle_set_fallback(client, request.query_params, headers)
    when "/admin/killclient"
      handle_kill_client(client, request.query_params, headers)
    when "/admin/moveclients"
      handle_move_clients(client, request.query_params, headers)
    when "/admin/record"
      handle_record(client, request.query_params, headers)
    when "/admin/reload"
      handle_reload(client, headers)
    when "/admin/bans"
      handle_ban_add(client, request.query_params, headers)
    when "/admin/bans/remove"
      handle_ban_remove(client, request.query_params, headers)
    else
      send_response(client, 404, "Not found")
    end
  end

  private def handle_patch(client : IO, request : HTTP::Request, address : String)
    headers = request.headers
    prefix = "/api/v1/stations/"
    path = request.path
    unless path.starts_with?(prefix) && (mount = canonical_mount(path.lchop(prefix)))
      send_api_error(client, 404, "Not found", headers)
      return
    end
    unless station_authorized?(headers, mount, address)
      send_api_error(client, 401, "Authentication required", headers, "Lurcast Station API")
      return
    end
    content_type = headers["Content-Type"]?.try { |value| MIME::MediaType.parse?(value) }
    unless content_type.try(&.media_type) == "application/json"
      send_api_error(client, 415, "Content-Type must be application/json", headers)
      return
    end
    unless body = request.body
      send_api_error(client, 400, "JSON body is required", headers)
      return
    end
    unless mountpoint = get_mount(mount)
      send_api_error(client, 404, "Station not found", headers)
      return
    end
    if (content_length = headers["Content-Length"]?.try(&.to_i64)) && content_length > RadioAPI::MAX_UPDATE_BYTES
      send_api_error(client, 413, "JSON body is too large", headers)
      return
    end

    input = IO::Memory.new
    if IO.copy(body, input, RadioAPI::MAX_UPDATE_BYTES + 1) > RadioAPI::MAX_UPDATE_BYTES
      send_api_error(client, 413, "JSON body is too large", headers)
      return
    end
    input.rewind
    update = RadioAPI::Update.from_json(input)
    update.validate!
    mountpoint.update_station(update.name, update.description, update.genre, update.url, update.listed)
    if current_song = update.current_song
      mountpoint.update_metadata(current_song)
    end
    notify_extensions("apply a station update on #{mount}", &.station_updated(mount, mountpoint))
    response = RadioAPI.render_station(@config.public_url, mountpoint, ->mount_fields(String, Lurcast::MountView))
    send_json(client, response, headers)
  rescue ex : JSON::ParseException | ArgumentError
    send_api_error(client, 400, "Invalid JSON: #{ex.message}", request.headers)
  end

  private def handle_source(client : IO, body : IO?, mount : String, headers : HTTP::Headers, address : String, method : String)
    unless source_authorized?(headers, mount, address)
      request_authentication(client, "Lurcast Source")
      return
    end

    unless headers["Content-Type"]? || headers["Ice-Content"]? || headers["Icy-Content"]?
      send_response(client, 400, "Content-Type is required")
      return
    end
    if reason = source_rejection(mount, headers)
      send_response(client, 403, reason)
      return
    end

    mountpoint = attach_source(mount, client, headers, SourceProtocol::Icecast)

    unless mountpoint
      send_response(client, 409, "Mount point is busy or the source limit was reached")
      return
    end

    expect_continue = headers.includes_word?("Expect", "100-continue")
    if method == "SOURCE"
      send_source_response(client)
    elsif expect_continue && body.nil?
      client.print "HTTP/1.1 100 Continue\r\n\r\n"
      client.flush
    end

    set_read_timeout(client, @config.source_timeout_for)
    read_source(body || client, mountpoint)

    if method == "PUT"
      send_source_response(client)
    end
  ensure
    release_source(mount, mountpoint, client) if mountpoint
  end

  private def read_source(client : IO, mountpoint : MountPoint)
    buffer = Bytes.new(16_384)
    loop do
      count = client.read(buffer)
      break if count == 0
      mountpoint.publish(buffer[0, count])
    end
  end

  private def handle_listener(client : IO, mount : String, headers : HTTP::Headers, address : String, slot : ConnectionSlot, head : Bool)
    user_agent = headers["User-Agent"]? || ""
    client_ip = client_address(headers, address)
    if @bans.match(client_ip, user_agent, mount)
      send_banned(client, head)
      return
    end
    listener_id = next_listener_id
    listener_request = Lurcast::ListenerRequest.new(listener_id, mount, client_ip, headers)
    challenged = true
    if realm = listener_challenge(listener_request)
      request_authentication(client, realm)
      return
    end
    mountpoint = resolve_mount(mount)
    relay_requested = false
    if mountpoint.nil? && !head && request_relay(mount)
      relay_requested = true
      mountpoint = wait_for_mount(mount)
    end
    if reason = listener_rejection(mount)
      send_response(client, 403, reason)
      return
    end
    unless mountpoint
      send_response(client, 404, "Stream not found")
      return
    end

    reservation = reserve_listener(mountpoint)
    if reservation.mount_full? && @config.fallback_when_full?(mount)
      if fallback = resolve_mount(@config.fallback_for(mount), mountpoint)
        fallback_reservation = reserve_listener(fallback)
        if fallback_reservation.reserved?
          mountpoint = fallback
          reservation = fallback_reservation
        end
      end
    end
    unless reservation.reserved?
      send_response(client, 503, "Listener limit reached")
      return
    end
    reserved_mountpoint = mountpoint
    unless head
      unless promote_to_listener(address, slot)
        send_response(client, 429, "Too many listeners from this address")
        return
      end
      listener_ip_held = true
    end

    wants_metadata = headers["Icy-MetaData"]? == "1" && mountpoint.supports_icy_metadata?
    protocol = headers["User-Agent"]?.try(&.downcase.includes?("winamp")) ? "ICY" : "HTTP/1.0"
    details = mountpoint.station_details
    response_head = String.build do |io|
      io << protocol << " 200 OK\r\n"
      io << "Server: " << SERVER_ID << "\r\n"
      io << "Content-Type: " << mountpoint.content_type << "\r\n"
      io << "Cache-Control: no-cache, no-store\r\n"
      io << "Connection: close\r\n"
      io << "icy-name: " << safe_header(details.name) << "\r\n"
      io << "icy-genre: " << safe_header(details.genre) << "\r\n"
      io << "icy-url: " << safe_header(details.url) << "\r\n"
      io << "icy-br: " << mountpoint.bitrate << "\r\n"
      io << "icy-metaint: " << mountpoint.metadata_interval << "\r\n" if wants_metadata
      cors_headers(headers).try(&.serialize(io))
      io << "\r\n"
    end
    client.write(response_head.to_slice)
    client.flush
    note_response(client, 200, 0_i64)
    return if head

    country = listener_country(client_ip)
    listener = mountpoint.add_listener(client, client_ip, wants_metadata, mount, id: listener_id, user_agent: user_agent, intro: intro_audio(mount), country: country)
    connection = Lurcast::ListenerConnection.new(listener_id, mount, client_ip, user_agent, country)
    notify_extensions("record a new listener", &.listener_connected(connection))
    activate_listener(mountpoint)
    listener_attached = true
    if relay_requested
      clear_relay_request(mount)
      relay_requested = false
    end
    spawn monitor_listener(listener)
    listener.wait_closed(@config.max_listener_duration_for(mount).try(&.seconds))
  ensure
    clear_relay_request(mount) if relay_requested
    if listener
      listener.owner.remove_listener(client)
    else
      mountpoint.try(&.remove_listener(client))
    end
    release_listener(reserved_mountpoint, listener_attached) if reserved_mountpoint
    release_listener_address(address) if listener_ip_held
    if listener
      note_response(client, 200, listener.bytes_sent)
      report_listener_session(listener, mount)
    end
    if challenged && listener_request
      notify_extensions("record a listener leaving", &.listener_closed(listener_request))
    end
  end

  private def report_listener_session(listener : MountPoint::Listener, mount : String)
    return if @extensions.empty?
    session = Lurcast::ListenerSession.new(
      id: listener.id,
      mount: mount,
      address: listener.address,
      user_agent: listener.user_agent,
      started_at: listener.started_at,
      duration: Time.instant - listener.connected_at,
      bytes_sent: listener.bytes_sent,
      unbilled_bytes: listener.take_unbilled_bytes,
      country: listener.country,
    )
    @extensions.each do |extension|
      extension.listener_finished(session)
    rescue ex
      Log.error(exception: ex) { "Extension failed to record a listener session on #{mount}" }
    end
  end

  private def monitor_listener(listener : MountPoint::Listener)
    byte = uninitialized UInt8[1]
    until listener.closed?
      begin
        break if listener.io.read(byte.to_slice) == 0
      rescue IO::TimeoutError
      end
    end
  rescue IO::Error
  ensure
    listener.owner.remove_listener(listener.io)
    listener.close
  end

  # Intro files are sent once to each new listener before the live burst.
  private def intro_audio(mount : String) : Bytes
    return Bytes.empty unless intro = @config.intro_for(mount)
    unless path = webroot_file(intro)
      Log.warn { "Intro #{intro} for #{mount} is not a file inside webroot" }
      return Bytes.empty
    end
    if File.size(path) > MAX_INTRO_BYTES
      Log.warn { "Intro #{intro} for #{mount} exceeds #{MAX_INTRO_BYTES} bytes" }
      return Bytes.empty
    end
    File.open(path) do |file|
      bytes = Bytes.new(file.size)
      file.read_fully(bytes)
      bytes
    end
  rescue ex : File::Error | IO::Error
    Log.warn { "Intro #{intro} for #{mount} failed: #{ex.message}" }
    Bytes.empty
  end

  private def handle_playlist(client : IO, path : String, headers : HTTP::Headers, head : Bool)
    mount = canonical_mount(path)
    unless mount && get_mount(mount)
      send_response(client, 404, "Stream not found")
      return
    end

    body = "#{@config.public_url.rstrip('/')}#{mount}\n"
    send_response(client, 200, body, "audio/x-mpegurl", cors_headers(headers), head: head)
  end

  private def handle_metadata(client : IO, params : HTTP::Params, headers : HTTP::Headers, address : String)
    mount = params["mount"]?.try { |value| canonical_mount(value) }
    unless mount && station_authorized?(headers, mount, address)
      request_authentication(client, "Lurcast Admin")
      return
    end

    song = params["song"]? || params["title"]?
    unless mount && song && (mountpoint = get_mount(mount))
      send_response(client, 400, "mount and song are required for an active stream")
      return
    end

    mountpoint.update_metadata(song)
    send_response(client, 200, "Metadata update successful")
  end

  private def handle_kill_source(client : IO, params : HTTP::Params, headers : HTTP::Headers)
    access = require_admin(client, headers) || return
    unless mountpoint = admin_mount(params, access)
      send_response(client, 404, "Stream not found")
      return
    end

    mountpoint.close_source
    send_response(client, 200, "Source disconnected")
  end

  private def handle_set_fallback(client : IO, params : HTTP::Params, headers : HTTP::Headers)
    access = require_admin(client, headers) || return
    mount = params["mount"]?.try { |value| canonical_mount(value) }
    if mount && !access.allows?(mount)
      send_response(client, 404, "Stream not found")
      return
    end
    if mount && params["fallback"]? == ""
      @config.clear_fallback(mount)
      send_response(client, 200, "Fallback removed")
      return
    end
    fallback = params["fallback"]?.try { |value| canonical_mount(value) }
    unless mount && fallback && mount != fallback && access.allows?(fallback)
      send_response(client, 400, "mount and fallback must be different mount points")
      return
    end

    @config.set_fallback(mount, fallback)
    send_response(client, 200, "Fallback updated")
  end

  private def attach_source(mount : String, source : IO, headers : HTTP::Headers, protocol : SourceProtocol) : MountPoint?
    mountpoint = @streams_mutex.synchronize do
      existing = @streams[mount]?
      if existing.try(&.has_source?)
        nil
      elsif existing.nil? && @streams.count { |_name, point| !point.source_protocol.in?(SourceProtocol::File, SourceProtocol::Internal) } >= @config.max_sources
        nil
      else
        point = existing || build_mount(mount, headers, protocol)
        point.apply_headers(headers)
        point.connect_source(source, protocol)
        @streams[mount] = point
        point
      end
    end

    if mountpoint && @config.fallback_override_for?(mount)
      returning = streams.reject { |stream| stream == mountpoint || !stream.compatible_with?(mountpoint) }
        .flat_map(&.detach_listeners(mount))
      mountpoint.adopt_listeners(returning)
    end
    if mountpoint
      notify_extensions("start a source on #{mount}", &.source_connected(mount, mountpoint))
      source_connected(mount, mountpoint)
    end
    mountpoint
  end

  private def release_source(mount : String, mountpoint : MountPoint, source : IO)
    released = @streams_mutex.synchronize do
      if @streams[mount]? == mountpoint && mountpoint.source == source
        @streams.delete(mount)
        true
      else
        false
      end
    end
    return unless released

    mountpoint.disconnect_source
    notify_extensions("end a source on #{mount}", &.source_disconnected(mount, mountpoint))
    source_disconnected(mount, mountpoint)
    listeners = mountpoint.detach_listeners
    if running? && (fallback = resolve_mount(@config.fallback_for(mount), mountpoint))
      fallback.adopt_listeners(listeners)
    else
      listeners.each(&.close)
    end
  end

  private def resolve_mount(mount : String?, compatible_with : MountPoint? = nil) : MountPoint?
    current = mount
    (@config.fallback_count + 1).times do
      return unless current
      if point = get_mount(current)
        return point if point.has_source? && (!compatible_with || point.compatible_with?(compatible_with))
      elsif point = start_fallback_file(current, compatible_with)
        return point
      end
      current = @config.fallback_for(current)
    end
    nil
  end

  private def start_fallback_file(mount : String, compatible_with : MountPoint?) : MountPoint?
    return unless @config.fallback_target?(mount)
    path = fallback_file_path(mount)
    return unless path

    headers = HTTP::Headers{
      "Content-Type" => fallback_content_type(path),
      "Icy-Br"       => @config.fallback_file_bitrate.to_s,
      "Icy-Name"     => File.basename(path),
    }
    point = build_mount(mount)
    point.apply_headers(headers)
    return if compatible_with && !point.compatible_with?(compatible_with)

    file = File.open(path)
    created = @streams_mutex.synchronize do
      if @streams.has_key?(mount)
        false
      else
        point.connect_source(file, SourceProtocol::File)
        @streams[mount] = point
        true
      end
    end
    unless created
      file.close
      return get_mount(mount).try { |existing| existing if existing.has_source? && (!compatible_with || existing.compatible_with?(compatible_with)) }
    end

    notify_extensions("start a source on #{mount}", &.source_connected(mount, point))
    spawn fallback_file_loop(mount, point, file), name: "fallback file"
    point
  rescue ex : File::Error
    Log.warn { "Fallback file #{mount} failed: #{ex.message}" }
    nil
  end

  private def build_mount(mount : String, headers : HTTP::Headers? = nil, protocol = SourceProtocol::Unknown) : MountPoint
    source_interval = icy_metadata_interval(headers) if protocol.relay?
    point = MountPoint.new(
      mount,
      @config.burst_size_for(mount),
      @config.queue_size_for(mount),
      @config.metadata_interval_for(mount, source_interval),
      @config.song_history_size,
    )
    point.on_song_change = ->(song : String, at : Time) { notify_song_change(mount, point, song, at) }
    point
  end

  private def notify_song_change(mount : String, point : MountPoint, song : String, at : Time) : Nil
    listeners = point.listener_count
    notify_extensions("record a song change on #{mount}", &.song_changed(mount, song, listeners, at))
  end

  # Calls *block* with every extension, logging the failures of one without stopping the others.
  private def notify_extensions(action : String, &)
    @extensions.each do |extension|
      yield extension
    rescue ex
      Log.error(exception: ex) { "Extension failed to #{action}" }
    end
  end

  private def icy_metadata_interval(headers : HTTP::Headers?) : Int32?
    headers.try(&.["Icy-MetaInt"]?).try(&.to_i?).try { |value| value if value.positive? }
  end

  private def fallback_file_path(mount : String) : String?
    webroot_file(mount)
  end

  private def webroot_file(relative : String) : String?
    webroot = @config.webroot
    return unless webroot
    root = File.realpath(webroot)
    path = File.realpath(File.join(root, relative.lstrip('/')))
    prefix = root.ends_with?(File::SEPARATOR) ? root : root + File::SEPARATOR_STRING
    path if path.starts_with?(prefix) && File.file?(path)
  rescue File::Error
    nil
  end

  private def fallback_content_type(path : String) : String
    case File.extname(path).downcase
    when ".aac"  then "audio/aac"
    when ".aacp" then "audio/aacp"
    else              MIME.from_filename(path, "application/octet-stream")
    end
  end

  private def fallback_file_loop(mount : String, point : MountPoint, file : File)
    # ponytail: fallback files use bitrate pacing; parse codec timestamps if sample-exact timing matters.
    buffer = Bytes.new(4096)
    pacer = Pacer.new(@config.fallback_file_bitrate * 1000 / 8.0)
    idle_since = nil.as(Time::Instant?)
    while running? && get_mount(mount) == point && point.source == file
      if point.listener_count == 0
        idle_since ||= Time.instant
        break if Time.instant - idle_since >= 1.second
        sleep 10.milliseconds
        next
      end
      pacer.restart if idle_since
      idle_since = nil

      count = file.read(buffer)
      if count == 0
        file.rewind
        next
      end
      point.publish(buffer[0, count])
      sleep pacer.sent(count)
    end
  rescue ex : IO::Error
    Log.debug { "Fallback file #{mount} stopped: #{ex.message}" }
  ensure
    release_source(mount, point, file)
  end

  private def mutating_request?(method : String, path : String) : Bool
    return true if method.in?("POST", "PATCH")
    method.in?("GET", "HEAD") && path.in?(MUTATING_PATHS)
  end

  private def status_json(listed : Array(MountPoint)) : String
    IcecastAPI.render(SERVER_ID, @start_time, listed, ->(mount : String) { mount_fields(mount, Lurcast::MountView::Status) })
  end

  # Streams shown on unauthenticated status pages; `hidden` mounts stay visible to admins.
  private def public_streams : Array(MountPoint)
    streams.reject { |stream| @config.hidden?(stream.mount) }
  end

  private def listeners_json : String
    streams.to_h { |stream| {stream.mount, stream.listener_addresses} }.to_json
  end

  private def canonical_mount(path : String) : String?
    return @config.shoutcast_mount if path == "/;"
    if path.starts_with?("/stream/")
      alias_name = path.lchop("/stream/")
      if sid = alias_name.to_i?
        return @config.shoutcast_mount_for(sid)
      end
      path = alias_name
    end
    path = "/#{path}" unless path.starts_with?('/')
    path if valid_mount?(path)
  end

  private def valid_mount?(path : String) : Bool
    path.starts_with?('/') && path != "/" && path.each_byte.none? { |byte| byte < 0x20 || byte == 0x7f }
  end

  private def authenticate(headers : HTTP::Headers, expected_user : String, expected_password : String) : Bool
    return false unless credentials = basic_credentials(headers)
    user, password = credentials
    user == expected_user && Crypto::Subtle.constant_time_compare(password, expected_password)
  end

  private def basic_credentials(headers : HTTP::Headers) : Tuple(String, String)?
    authorization = headers["Authorization"]?
    return unless authorization
    scheme, separator, token = authorization.partition(' ')
    return if separator.empty? || scheme.compare("Basic", case_insensitive: true) != 0
    decoded = Base64.decode_string(token.lstrip)
    user, separator, password = decoded.partition(':')
    return if separator.empty?
    {user, password}
  rescue Base64::Error
    nil
  end

  private def source_authorized?(headers : HTTP::Headers, mount : String, address : String) : Bool
    user, password = source_credentials(headers)
    source_credentials_authorized?(mount, address, user, password)
  end

  private def station_authorized?(headers : HTTP::Headers, mount : String, address : String) : Bool
    return true if admin_access(headers).try(&.allows?(mount))
    user, password = source_credentials(headers)
    source_credentials_authorized?(mount, address, user, password, admin: true)
  end

  private def source_credentials(headers : HTTP::Headers) : Tuple(String, String)
    basic_credentials(headers) || {"source", headers["Ice-Password"]? || ""}
  end

  private def source_credentials_authorized?(mount : String, address : String, user : String, password : String, admin = false) : Bool
    decided = source_login(mount, address, user, password, admin)
    return decided unless decided.nil?
    {user, password} == @config.source_credentials_for(mount)
  end

  # SHOUTcast sources send only a password, unless an extension checks the login.
  private def uvox_source_authorized?(mount : String, address : String, user : String, password : String) : Bool
    decided = source_login(mount, address, user, password, false)
    return decided unless decided.nil?
    password == @config.source_credentials_for(mount)[1]
  end

  private def source_login(mount : String, address : String, user : String, password : String, admin : Bool) : Bool?
    @extensions.each do |extension|
      decided = extension.source_login(mount, address, user, password, admin)
      return decided unless decided.nil?
    end
    nil
  end

  private def next_listener_id : Int64
    @next_listener_id.add(1_i64) + 1
  end

  private def request_authentication(client : IO, realm : String)
    send_response(client, 401, "Authentication required", extra_headers: HTTP::Headers{"WWW-Authenticate" => "Basic realm=\"#{realm}\""})
  end

  private def send_source_response(client : IO)
    client.write("HTTP/1.0 200 OK\r\nServer: #{SERVER_ID}\r\nConnection: close\r\n\r\n".to_slice)
    client.flush
  end

  private def send_json(client : IO, body : String, request_headers : HTTP::Headers, *, head = false)
    send_response(client, 200, body, "application/json", cors_headers(request_headers), head: head)
  end

  private def send_response(client : IO, status : Int32, body : String, content_type = "text/plain; charset=utf-8", extra_headers : HTTP::Headers? = nil, *, head = false)
    write_response(client, status, body.to_slice, content_type, extra_headers, head)
  end

  # Bodies up to this size go out in the same write as the response head.
  COMBINED_WRITE_LIMIT = 64 * 1024

  private def write_response(client : IO, status : Int32, body : Bytes, content_type : String, headers : HTTP::Headers?, head : Bool)
    return if client.closed?
    head_bytes = response_head(status, content_type, body.size.to_i64, headers).to_slice
    if head || body.empty?
      client.write(head_bytes)
    elsif body.size <= COMBINED_WRITE_LIMIT
      combined = Bytes.new(head_bytes.size + body.size)
      head_bytes.copy_to(combined)
      body.copy_to(combined + head_bytes.size)
      client.write(combined)
    else
      client.write(head_bytes)
      client.write(body)
    end
    client.flush
    note_response(client, status, head ? 0_i64 : body.size.to_i64)
  rescue IO::Error
  end

  private def response_head(status : Int32, content_type : String, length : Int64, headers : HTTP::Headers? = nil) : String
    String.build do |io|
      io << "HTTP/1.0 " << status << ' ' << (HTTP::Status.new(status).description || "Unknown") << "\r\n"
      io << "Server: " << SERVER_ID << "\r\nContent-Type: " << content_type << "\r\nContent-Length: " << length
      io << "\r\nConnection: close\r\n"
      headers.try(&.serialize(io))
      io << "\r\n"
    end
  end

  private def send_api_error(client : IO, status : Int32, message : String, request_headers : HTTP::Headers, realm : String? = nil)
    headers = cors_headers(request_headers)
    if realm
      headers ||= HTTP::Headers.new
      headers["WWW-Authenticate"] = "Basic realm=\"#{realm}\""
    end
    send_response(client, status, RadioAPI::Error.new(message).to_json, "application/json", headers)
  end

  private def cors_headers(headers : HTTP::Headers) : HTTP::Headers?
    origin = headers["Origin"]?
    allowed = if @config.allowed_origins.includes?("*")
                "*"
              elsif origin && @config.allowed_origins.includes?(origin)
                origin
              end
    return unless allowed

    response = HTTP::Headers{"Access-Control-Allow-Origin" => allowed}
    response["Vary"] = "Origin" unless allowed == "*"
    response
  end

  private def safe_header(value : String) : String
    value.tr("\r\n", " ")
  end

  private def remote_address(client : TCPSocket) : String
    address = client.remote_address.as(Socket::IPAddress)
    address.address
  rescue Socket::Error
    "unknown"
  end

  # Client sockets stay unbuffered (`sync`), so a long-lived listener does not hold an 8 KiB write
  # buffer. With TCP_NODELAY every write is then its own packet, so responses assemble their head in
  # memory and write it in one call (see `write_response`).
  private def configure_socket(client : TCPSocket)
    client.read_timeout = @config.header_timeout_for.seconds
    client.write_timeout = @config.timeout.seconds
    client.tcp_nodelay = true
    client.keepalive = true
  end

  private def set_read_timeout(io : IO, seconds : Int32)
    case io
    when Socket, IO::FileDescriptor, OpenSSL::SSL::Socket
      io.read_timeout = seconds.seconds
    end
  end

  private def begin_request(ip : String) : Bool
    @limits_mutex.synchronize do
      connections = @connections[ip]
      return false if connections >= @config.max_connections_per_ip

      now = Time.instant
      cutoff = now - @config.rate_limit_window.seconds
      prune_request_history(now, cutoff)
      requests = @requests.put_if_absent(ip) { [] of Time::Instant }
      requests.reject! { |time| time < cutoff }
      return false if requests.size >= @config.rate_limit

      requests << now
      @connections[ip] = connections + 1
      true
    end
  end

  # Drops addresses with no requests inside the window, at most once per window, so the map
  # tracks only recent clients instead of every address ever seen. Caller holds @limits_mutex.
  private def prune_request_history(now : Time::Instant, cutoff : Time::Instant)
    return if (last = @last_request_prune) && last > cutoff
    @last_request_prune = now
    @requests.reject! { |_ip, times| times.empty? || times.last < cutoff }
  end

  # Takes a request back out of *ip*'s count for `rate_limit`: players fetch HLS playlists and
  # segments all the time, which is listening, not a flood. `max_connections_per_ip` still applies.
  def listener_request(ip : String) : Nil
    @limits_mutex.synchronize { @requests[ip]?.try(&.pop?) }
  end

  private def end_request(ip : String)
    @limits_mutex.synchronize { decrement(@connections, ip) }
  end

  # Swaps the request's connection slot for a listener slot, enforcing `max_listeners_per_ip`.
  private def promote_to_listener(ip : String, slot : ConnectionSlot) : Bool
    @limits_mutex.synchronize do
      count = @listener_addresses[ip]
      return false if @config.max_listeners_per_ip.try { |maximum| count >= maximum }

      @listener_addresses[ip] = count + 1
      decrement(@connections, ip) if slot.held?
      slot.held = false
      true
    end
  end

  private def release_listener_address(ip : String)
    @limits_mutex.synchronize { decrement(@listener_addresses, ip) }
  end

  # Caller holds @limits_mutex.
  private def decrement(counts : Hash(String, Int32), ip : String)
    count = counts[ip] - 1
    if count > 0
      counts[ip] = count
    else
      counts.delete(ip)
    end
  end

  private def reserve_listener(mountpoint : MountPoint) : ListenerReservation
    @limits_mutex.synchronize do
      return ListenerReservation::GlobalFull if @active_listeners >= @config.max_listeners

      id = mountpoint.object_id
      if maximum = @config.max_listeners_for(mountpoint.mount)
        current = mountpoint.listener_count + @pending_listeners[id]
        return ListenerReservation::MountFull if current >= maximum
      end

      @active_listeners += 1
      @pending_listeners[id] += 1
      ListenerReservation::Reserved
    end
  end

  private def activate_listener(mountpoint : MountPoint)
    @limits_mutex.synchronize { remove_pending_listener(mountpoint.object_id) }
  end

  private def release_listener(mountpoint : MountPoint, attached : Bool?)
    @limits_mutex.synchronize do
      @active_listeners -= 1
      remove_pending_listener(mountpoint.object_id) unless attached
    end
  end

  private def remove_pending_listener(id : UInt64)
    remaining = @pending_listeners[id] - 1
    if remaining.positive?
      @pending_listeners[id] = remaining
    else
      @pending_listeners.delete(id)
    end
  end

  private def interruptible_sleep(seconds : Int32)
    deadline = Time.instant + seconds.seconds
    while running?
      remaining = deadline - Time.instant
      break unless remaining.positive?
      sleep Math.min(remaining, 100.milliseconds)
    end
  end

  # Public helpers for extensions.

  def respond(client : IO, status : Int32, body : String, content_type = "text/plain; charset=utf-8", headers : HTTP::Headers? = nil) : Nil
    send_response(client, status, body, content_type, headers)
  end

  def admin?(headers : HTTP::Headers) : Bool
    authenticate(headers, "admin", @config.admin_password)
  end

  # Disconnects the source and every listener of *mount*, without moving listeners to a fallback.
  def disconnect_mount(mount : String) : Nil
    return unless point = get_mount(mount)
    point.close_listeners
    point.close_source
  end

  def source_rejection(mount : String, headers : HTTP::Headers) : String?
    @extensions.each do |extension|
      if reason = extension.source_rejection(mount, headers)
        return reason
      end
    end
    nil
  end

  def listener_rejection(mount : String) : String?
    @extensions.each do |extension|
      if reason = extension.listener_rejection(mount)
        return reason
      end
    end
    nil
  end

  # The realm to ask a listener of *mount* to sign in to, when an extension protects the mount and the
  # request has no valid login.
  def listener_challenge(request : Lurcast::ListenerRequest) : String?
    @extensions.each do |extension|
      if realm = extension.listener_challenge(request)
        return realm
      end
    end
    nil
  end

  # Whether an extension must see every listener of *mount* as a connection of its own.
  def each_listener_checked?(mount : String) : Bool
    @extensions.any?(&.checks_each_listener?(mount))
  end

  # Listeners of *mount* that extensions serve without a stream connection.
  def extra_listeners(mount : String) : Int32
    @extensions.sum(&.listener_count(mount))
  end

  # The fields extensions add to *mount* in *view*.
  def mount_fields(mount : String, view : Lurcast::MountView) : Hash(String, JSON::Any)
    fields = {} of String => JSON::Any
    @extensions.each do |extension|
      extension.mount_fields(mount, view).try { |more| fields.merge!(more) }
    rescue ex
      Log.error(exception: ex) { "Extension failed to describe #{mount}" }
    end
    fields
  end

  # Checks a request to play *mount* that is not a stream connection (an HLS playlist or segment)
  # against the ban list and the extensions' `listener_challenge`. Answers 403 or 401 and returns true when
  # it may not.
  def listener_refused?(client : IO, mount : String, headers : HTTP::Headers, address : String, *, head = false) : Bool
    client_ip = client_address(headers, address)
    if listener_ban(client_ip, headers, mount)
      send_banned(client, head)
      return true
    end
    if realm = listener_challenge(Lurcast::ListenerRequest.new(nil, mount, client_ip, headers))
      request_authentication(client, realm)
      return true
    end
    false
  end

  # The CORS headers to answer a request with, or nil when its origin isn't allowed.
  def cors_headers_for(headers : HTTP::Headers) : HTTP::Headers?
    cors_headers(headers)
  end

  # Sends a binary body, such as an image.
  def respond_bytes(client : IO, status : Int32, body : Bytes, content_type : String, headers : HTTP::Headers? = nil, *, head = false) : Nil
    write_response(client, status, body, content_type, headers, head)
  end

  # Answers 401, asking for a login to *realm*.
  def challenge(client : IO, realm : String) : Nil
    request_authentication(client, realm)
  end

  # The login in *headers*: the server admin or a login an extension grants; nil when missing or wrong.
  def admin_login(headers : HTTP::Headers) : AdminAccess?
    admin_access(headers)
  end

  # The address of the client: the socket *address*, or the forwarded one behind a trusted proxy.
  def client_ip(headers : HTTP::Headers, address : String) : String
    client_address(headers, address)
  end

  # The mount named by *path* (`/live`, `live`, a SHOUTcast stream number alias), or nil if invalid.
  def mount_name(path : String) : String?
    canonical_mount(path)
  end

  # Publishes what *source* produces on *mount*, like a source client connected to the server, until
  # *source* ends or is closed. Returns false at once when the mount already has a source.
  def serve_source(mount : String, source : IO, headers : HTTP::Headers) : Bool
    mountpoint = attach_source(mount, source, headers, SourceProtocol::Internal)
    return false unless mountpoint
    begin
      read_source(source, mountpoint)
    rescue ex : IO::Error
      Log.debug { "Internal source for #{mount} stopped: #{ex.message}" }
    ensure
      release_source(mount, mountpoint, source)
    end
    true
  end

  # Sets the certificate for TLS connections, for example after renewing it.
  def tls_context=(context : OpenSSL::SSL::Context::Server) : Nil
    @tls_context = context
  end

  private def running? : Bool
    @running.get
  end
end

require "./icecast_server/admin"
require "./icecast_server/dashboard"
require "./icecast_server/features"
require "./icecast_server/moderation"
require "./icecast_server/relays"
require "./icecast_server/shoutcast_source"
require "./icecast_server/ultravox_source"
