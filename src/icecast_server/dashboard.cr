class IcecastServer
  ADMIN_PAGE_CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; " \
                   "connect-src 'self'; media-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
  PUBLIC_PAGE_CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; " \
                    "connect-src 'self'; media-src 'self'; base-uri 'none'; form-action 'self'"

  private def handle_asset(client : IO, name : String, params : HTTP::Params, headers : HTTP::Headers, head : Bool)
    unless asset = WebAssets::FILES[name]?
      send_response(client, 404, "Not found", head: head)
      return
    end
    content_type, body = asset
    etag = %("#{WebAssets::VERSION}")
    cache = params["v"]? == WebAssets::VERSION ? "public, max-age=31536000, immutable" : "no-cache"
    response_headers = HTTP::Headers{
      "Cache-Control"          => cache,
      "ETag"                   => etag,
      "Vary"                   => "Accept-Encoding",
      "X-Content-Type-Options" => "nosniff",
    }
    if headers["If-None-Match"]? == etag
      send_response(client, 304, "", content_type, response_headers, head: true)
    elsif headers["Accept-Encoding"]?.try(&.includes?("gzip"))
      response_headers["Content-Encoding"] = "gzip"
      send_binary(client, WebAssets::GZIPPED[name], content_type, response_headers, head)
    else
      send_response(client, 200, body, content_type, response_headers, head: head)
    end
  end

  private def send_page(client : IO, body : String, csp : String, head : Bool, *, frameable = true)
    headers = HTTP::Headers{
      "Content-Security-Policy" => csp,
      "X-Content-Type-Options"  => "nosniff",
      "Referrer-Policy"         => "same-origin",
      "Cache-Control"           => "no-cache",
    }
    headers["X-Frame-Options"] = "DENY" unless frameable
    send_response(client, 200, body, "text/html; charset=utf-8", headers, head: head)
  end

  # The dashboard page holds no data, so it needs no credentials. `admin.js` signs in with its own
  # form and sends the password on each request, so the browser never caches admin credentials
  # that other sites could ride on.
  private def handle_admin_page(client : IO, head : Bool)
    send_page(client, Templates.admin, ADMIN_PAGE_CSP, head, frameable: false)
  end

  # Everything the dashboard shows, in one response. Unlike the other JSON endpoints, it sends no
  # CORS headers, and a failed sign-in gets no `WWW-Authenticate` challenge, so the browser shows no
  # password prompt of its own.
  private def handle_admin_overview(client : IO, params : HTTP::Params, headers : HTTP::Headers, head : Bool)
    unless access = admin_access(headers)
      send_response(client, 401, %({"error":"Wrong username or password"}), "application/json", HTTP::Headers{"Cache-Control" => "no-store"}, head: head)
      return
    end
    send_admin_json(client, admin_overview(access, params["clients"]?).to_json, head)
  end

  # What *access* may see. *clients_for* names the one mount whose listener list to include. For a
  # login limited to some mounts, the server figures cover only those mounts.
  private def admin_overview(access : AdminAccess, clients_for : String? = nil) : AdminAPI::Overview
    live = streams.select { |stream| access.allows?(stream.mount) }.to_h { |stream| {stream.mount, stream} }
    relays = @config.relays.to_h { |relay| {relay.mount, relay} }
    sids = {1 => @config.shoutcast_mount}.merge(@config.shoutcast_mounts).to_h { |sid, mount| {mount, sid} }
    names = live.keys | @config.mounts.keys | relays.keys
    names |= sids.keys if @config.shoutcast_port
    names.select! { |name| access.allows?(name) }
    base_url = @config.public_url.rstrip('/')
    full = access.full?

    AdminAPI::Overview.new(
      server: AdminAPI::Server.new(
        id: SERVER_ID,
        hostname: @config.hostname,
        public_url: @config.public_url,
        started_at: @start_time,
        uptime_seconds: (Time.utc - @start_time).total_seconds.to_i64,
        listeners: live.each_value.sum(&.listener_count),
        max_listeners: full ? @config.max_listeners : names.sum { |name| @config.max_listeners_for(name) || @config.max_listeners },
        sources: live.each_value.count { |stream| stream.has_source? && !stream.source_protocol.file? },
        max_sources: full ? @config.max_sources : names.size,
        port: @config.port,
        tls_port: @config.tls_port,
        shoutcast_port: @config.shoutcast_port,
        default_passwords: full ? @config.default_password_settings : [] of String,
        features: AdminAPI::Features.new(
          reload: full && !@config_path.nil?,
          recordings: !@config.recordings_dir.nil?,
          hls: @config.hls?,
          locations: locations_source,
          bans_saved: @bans.persistent?,
          history_saved: !@config.data_dir.nil?,
          plugins: @extensions.compact_map { |extension| extension.as?(Lurcast::Plugin).try(&.name) },
        ),
      ),
      access: AdminAPI::Access.new(access.user, full),
      mounts: names.sort.map { |name| admin_mount(name, live[name]?, relays[name]?, sids[name]?, base_url, name == clients_for) },
    )
  end

  private def admin_mount(name : String, stream : MountPoint?, relay : RelayConfig?, sid : Int32?, base_url : String, clients : Bool) : AdminAPI::Mount
    recording = recording_for(name).try do |active|
      AdminAPI::Recording.new(active.started_at, active.current_path.try { |path| File.basename(path) }, active.manual?)
    end
    hls = hls_segmenter(name)
    mount = AdminAPI::Mount.new(
      mount: name,
      listen_url: "#{base_url}#{name}",
      hidden: @config.hidden?(name),
      fallback: @config.fallback_for(name),
      max_listeners: @config.max_listeners_for(name),
      source_username: @config.source_credentials_for(name)[0],
      relay_url: relay.try(&.url),
      shoutcast_sid: sid,
      online: stream.try(&.has_source?) || false,
      record: @config.record?(name),
      recording: recording,
      hls_url: hls ? "#{base_url}#{name}.m3u8" : nil,
      hls_listeners: hls ? hls_listener_count(name) : nil,
      artwork: artwork_url(name),
    )
    return mount unless stream
    format = Templates.format_label(stream.content_type, stream.mp3_info.try(&.bitrate_kbps) || stream.bitrate)
    mount.with_live(stream, format, countries: !locations_source.nil?, clients: clients)
  end

  # Admin actions accept Basic credentials, which a browser attaches by itself after anyone types
  # them into its password prompt. Forms, links, and images on another site therefore must not be
  # able to trigger them. Scripts, encoders, control panels, and cross-site `fetch` calls (which must
  # set credentials explicitly) send different or no `Sec-Fetch-*` headers and are unaffected, as
  # are SHOUTcast requests that carry `pass=` in the URL.
  private def cross_site_form?(headers : HTTP::Headers, params : HTTP::Params) : Bool
    return false if params.has_key?("pass")
    site = headers["Sec-Fetch-Site"]?
    mode = headers["Sec-Fetch-Mode"]?
    return false unless site && mode
    site.in?("cross-site", "same-site") && mode.in?("navigate", "no-cors", "nested-navigate")
  end
end
