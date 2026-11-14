class IcecastServer
  # Icecast XML admin endpoints. They include hidden mounts because they require admin credentials;
  # a login limited to some mounts sees only those.
  private def handle_admin_xml(client : IO, path : String, params : HTTP::Params, headers : HTTP::Headers, head : Bool)
    access = require_admin(client, headers) || return
    visible = streams.select { |stream| access.allows?(stream.mount) }

    body = case path
           when "/admin/listmounts"
             IcecastXML.list_mounts(visible)
           when "/admin/listclients"
             unless mountpoint = admin_mount(params, access)
               send_xml(client, IcecastXML.response("Source does not exist", false), headers, 400, head: head)
               return
             end
             IcecastXML.list_clients(mountpoint)
           else
             IcecastXML.stats(xml_server_info, visible) { |stream| @config.max_listeners_for(stream.mount) }
           end
    send_xml(client, body, headers, head: head)
  end

  private def handle_kill_client(client : IO, params : HTTP::Params, headers : HTTP::Headers)
    access = require_admin(client, headers) || return
    id = params["id"]?.try(&.to_i64?)
    mountpoint = admin_mount(params, access)
    unless mountpoint && id
      send_xml(client, IcecastXML.response("mount and numeric id are required", false), headers, 400)
      return
    end
    if mountpoint.kick_listener(id)
      send_xml(client, IcecastXML.response("Client #{id} removed"), headers)
    else
      send_xml(client, IcecastXML.response("Client #{id} not found", false), headers, 404)
    end
  end

  # Moves every listener, or only `id`, from `mount` to `destination`. The destination must be live and
  # carry the same stream format, because players cannot switch codecs mid-connection.
  private def handle_move_clients(client : IO, params : HTTP::Params, headers : HTTP::Headers)
    access = require_admin(client, headers) || return
    source = admin_mount(params, access)
    destination = params["destination"]?.try { |value| canonical_mount(value) }
      .try { |mount| get_mount(mount) if access.allows?(mount) }
    id_text = params["id"]?
    id = id_text.try(&.to_i64?)
    if source.nil? || destination.nil? || (id_text && id.nil?)
      send_xml(client, IcecastXML.response("mount and a live destination are required", false), headers, 400)
      return
    end
    if source == destination || !destination.has_source? || !destination.compatible_with?(source)
      send_xml(client, IcecastXML.response("Destination must be a different live mount with the same stream format", false), headers, 400)
      return
    end

    listeners = source.detach_listeners(id: id)
    destination.adopt_listeners(listeners)
    send_xml(client, IcecastXML.response("Clients moved from #{source.mount} to #{destination.mount}"), headers)
  end

  private def handle_shoutcast_stats(client : IO, path : String, params : HTTP::Params, headers : HTTP::Headers, head : Bool)
    if path == "/statistics"
      streams = shoutcast_streams
      if params["json"]? == "1"
        send_json(client, ShoutcastAPI.statistics_json(streams, SERVER_ID), headers, head: head)
      else
        send_xml(client, ShoutcastAPI.statistics_xml(streams, SERVER_ID), headers, head: head)
      end
      return
    end

    unless stream = shoutcast_stream(params)
      send_response(client, 404, "Stream not found", head: head)
      return
    end
    history = stream.mount.try(&.song_history) || [] of MountPoint::PlayedSong
    case path
    when "/7.html"
      body = ShoutcastAPI.seven_html(ShoutcastAPI.stats(stream, SERVER_ID))
      send_response(client, 200, body, "text/html; charset=utf-8", cors_headers(headers), head: head)
    when "/currentsong"
      send_response(client, 200, stream.mount.try(&.current_song) || "", "text/plain; charset=utf-8", cors_headers(headers), head: head)
    when "/played.html"
      title = stream.mount.try(&.station_details.name) || stream.path
      send_page(client, Templates.played(history, title), PUBLIC_PAGE_CSP, head)
    when "/played"
      if params["type"]? == "json"
        send_json(client, ShoutcastAPI.played_json(history), headers, head: head)
      else
        send_xml(client, ShoutcastAPI.played_xml(history), headers, head: head)
      end
    else
      stats = ShoutcastAPI.stats(stream, SERVER_ID)
      if params["json"]? == "1"
        send_json(client, ShoutcastAPI.stats_json(stats), headers, head: head)
      else
        send_xml(client, ShoutcastAPI.stats_xml(stats), headers, head: head)
      end
    end
  end

  # SHOUTcast `admin.cgi` modes: `updinfo` accepts source or admin credentials; the rest require admin.
  private def handle_shoutcast_admin(client : IO, params : HTTP::Params, headers : HTTP::Headers)
    mode = params["mode"]?
    unless mode.in?("updinfo", "viewxml", "viewjson", "kicksrc", "kickdst")
      send_response(client, 400, "mode must be updinfo, viewxml, viewjson, kicksrc, or kickdst")
      return
    end
    stream = shoutcast_stream(params)
    password = params["pass"]?
    admin = password == @config.admin_password || authenticate(headers, "admin", @config.admin_password)
    source = mode == "updinfo" && shoutcast_source_password?(stream.try(&.path), password, headers)
    unless admin || source
      request_authentication(client, "Lurcast Admin")
      return
    end
    unless stream
      send_response(client, 400, "valid sid is required")
      return
    end
    mountpoint = stream.mount

    case mode
    when "updinfo"
      song = params["song"]? || params["title"]?
      unless song && mountpoint
        send_response(client, 400, "valid sid and song are required for an active stream")
        return
      end
      mountpoint.update_metadata(song)
      mountpoint.update_station(url: params["url"]?)
      send_response(client, 200, "Metadata update successful")
    when "viewxml", "viewjson"
      stats = ShoutcastAPI.stats(stream, SERVER_ID)
      history = mountpoint.try(&.song_history) || [] of MountPoint::PlayedSong
      listeners = mountpoint.try(&.listener_details) || [] of MountPoint::ListenerInfo
      if mode == "viewjson"
        send_json(client, ShoutcastAPI.stats_json(stats, history, listeners), headers)
      else
        send_xml(client, ShoutcastAPI.stats_xml(stats, history, listeners), headers)
      end
    when "kicksrc"
      if mountpoint
        mountpoint.close_source
        send_response(client, 200, "Source disconnected")
      else
        send_response(client, 404, "Stream not found")
      end
    else
      target = params["kickdst"]?
      unless target && mountpoint
        send_response(client, 400, "kickdst and an active stream are required")
        return
      end
      removed = if id = target.to_i64?
                  mountpoint.kick_listener(id) ? 1 : 0
                else
                  mountpoint.kick_listeners_from(target)
                end
      send_response(client, removed.positive? ? 200 : 404, "#{removed} listener(s) disconnected")
    end
  end

  private def shoutcast_source_password?(mount : String?, password : String?, headers : HTTP::Headers) : Bool
    user, expected = mount ? @config.source_credentials_for(mount) : {"source", @config.source_password}
    password == expected || authenticate(headers, user, expected)
  end

  private def shoutcast_stream(params : HTTP::Params) : ShoutcastAPI::Stream?
    sid_text = params["sid"]?
    sid = sid_text ? sid_text.to_i? : 1
    return unless sid && (mount = @config.shoutcast_mount_for(sid))
    shoutcast_stream(sid, mount)
  end

  private def shoutcast_stream(sid : Int32, mount : String) : ShoutcastAPI::Stream
    ShoutcastAPI::Stream.new(sid, mount, get_mount(mount), @config.max_listeners_for(mount) || @config.max_listeners)
  end

  private def shoutcast_streams : Array(ShoutcastAPI::Stream)
    mounts = {1 => @config.shoutcast_mount}.merge(@config.shoutcast_mounts)
    mounts.to_a.sort_by!(&.[0]).compact_map do |sid, mount|
      shoutcast_stream(sid, mount) unless @config.hidden?(mount)
    end
  end

  private def xml_server_info : IcecastXML::ServerInfo
    IcecastXML::ServerInfo.new(SERVER_ID, @start_time, @config.hostname, @config.admin_email, @config.public_url)
  end

  private def send_xml(client : IO, body : String, request_headers : HTTP::Headers, status = 200, *, head = false)
    send_response(client, status, body, "text/xml; charset=utf-8", cors_headers(request_headers), head: head)
  end
end
