require "crypto/subtle"
require "../admin_access"
require "../ban_list"
require "../listener_history"

class IcecastServer
  HISTORY_INTERVAL   =  60
  HISTORY_SAVE_EVERY =  15
  BANS_PER_LOGIN     = 500

  record BanResult, ban : BanList::Ban, disconnected : Int32 do
    include JSON::Serializable
  end

  record BanListResponse, bans : Array(BanList::Ban), saved : Bool do
    include JSON::Serializable
  end

  @bans = BanList.new(nil)
  @history = ListenerHistory.new

  # ---------- Admin logins ----------

  # The login in *headers*: the server admin (user `admin` and `admin_password`), or a login an
  # extension grants for some mounts. Nil when the credentials are missing or wrong.
  private def admin_access(headers : HTTP::Headers) : AdminAccess?
    user, password = basic_credentials(headers) || return
    return AdminAccess.new(user) if user == "admin" && Crypto::Subtle.constant_time_compare(password, @config.admin_password)
    @extensions.each do |extension|
      if mounts = extension.admin_login(user, password)
        return AdminAccess.new(user, mounts)
      end
    end
    nil
  end

  # The login in *headers*; otherwise answers 401 and returns nil.
  private def require_admin(client : IO, headers : HTTP::Headers) : AdminAccess?
    access = admin_access(headers)
    request_authentication(client, "Lurcast Admin") unless access
    access
  end

  # The mount named in `mount=`, if it exists and *access* may manage it.
  private def admin_mount(params : HTTP::Params, access : AdminAccess) : MountPoint?
    mount = params["mount"]?.try { |value| canonical_mount(value) }
    get_mount(mount) if mount && access.allows?(mount)
  end

  # ---------- Bans ----------

  private def setup_bans_and_history
    @bans = BanList.new(data_path("bans.json"))
    @history = ListenerHistory.new(data_path("listener-history.bin"))
  end

  private def data_path(name : String) : String?
    @config.data_dir.try { |dir| File.join(dir, name) }
  end

  # The ban that refuses this listener, if any.
  private def listener_ban(address : String, headers : HTTP::Headers, mount : String) : BanList::Ban?
    @bans.match(address, headers["User-Agent"]? || "", mount)
  end

  private def send_banned(client : IO, head : Bool)
    send_response(client, 403, "You are not allowed to listen to this stream", head: head)
  end

  # Disconnects every current listener that a ban now refuses. Returns how many.
  private def disconnect_banned : Int32
    streams.sum do |stream|
      stream.listener_details.count do |listener|
        @bans.match(listener.address, listener.user_agent, stream.mount) && stream.kick_listener(listener.id)
      end
    end
  end

  private def handle_bans_list(client : IO, params : HTTP::Params, headers : HTTP::Headers, head : Bool)
    access = require_admin(client, headers) || return
    mount = params["mount"]?.try { |value| canonical_mount(value) }
    bans = @bans.list.select do |ban|
      scope = ban.mount
      visible = access.full? || (scope && access.allows?(scope))
      visible && (mount.nil? || ban.applies_to?(mount))
    end
    send_admin_json(client, BanListResponse.new(bans, @bans.persistent?).to_json, head)
  end

  # `kind` is `address` or `user_agent`; `mount` limits the ban to one mount (a login limited to some
  # mounts must name one); `minutes` makes it expire; `reason` is a note for other admins.
  private def handle_ban_add(client : IO, params : HTTP::Params, headers : HTTP::Headers)
    access = require_admin(client, headers) || return
    kind = BanList::Kind.parse?(params["kind"]? || "")
    value = params["value"]?
    unless kind && value
      return send_admin_error(client, 400, "kind (address or user_agent) and value are required")
    end
    mount = params["mount"]?.presence.try { |text| canonical_mount(text) || return send_admin_error(client, 400, "invalid mount") }
    if mount.nil? && !access.full?
      return send_admin_error(client, 400, "mount is required")
    end
    if mount && !access.allows?(mount)
      return send_admin_error(client, 404, "Stream not found")
    end
    minutes = params["minutes"]?.presence.try { |text| text.to_i? || return send_admin_error(client, 400, "minutes must be a whole number") }
    if !access.full? && @bans.list.count { |ban| ban.created_by == access.user } >= BANS_PER_LOGIN
      return send_admin_error(client, 409, "You already have #{BANS_PER_LOGIN} bans; remove some first")
    end

    ban = @bans.add(kind, value, mount: mount, reason: params["reason"]?, created_by: access.user,
      duration: minutes.try(&.minutes))
    Log.info { "#{access.user} banned #{ban.kind.to_s.underscore} #{ban.value}#{" on #{mount}" if mount}" }
    send_admin_json(client, BanResult.new(ban, disconnect_banned).to_json, false)
  rescue ex : ArgumentError
    send_admin_error(client, 400, ex.message || "Invalid ban")
  end

  private def handle_ban_remove(client : IO, params : HTTP::Params, headers : HTTP::Headers)
    access = require_admin(client, headers) || return
    ban = params["id"]?.try { |id| @bans.find(id) }
    scope = ban.try(&.mount)
    unless ban && (access.full? || (scope && access.allows?(scope)))
      return send_admin_error(client, 404, "Ban not found")
    end
    @bans.remove(ban.id)
    Log.info { "#{access.user} lifted the ban on #{ban.value}" }
    send_response(client, 200, "Ban removed")
  end

  private def send_admin_json(client : IO, body : String, head : Bool)
    headers = HTTP::Headers{"Cache-Control" => "no-store", "X-Content-Type-Options" => "nosniff"}
    send_response(client, 200, body, "application/json", headers, head: head)
  end

  private def send_admin_error(client : IO, status : Int32, message : String) : Nil
    send_response(client, status, {error: message}.to_json, "application/json", HTTP::Headers{"Cache-Control" => "no-store"})
  end

  # ---------- Listener history ----------

  private def history_loop
    samples = 0
    while running?
      interruptible_sleep(HISTORY_INTERVAL)
      break unless running?
      record_history_sample
      samples += 1
      @history.save if samples % HISTORY_SAVE_EVERY == 0
    end
  end

  private def record_history_sample(now = Time.utc) : Nil
    counts = streams.to_h { |stream| {stream.mount, stream.listener_count + extra_listeners(stream.mount)} }
    @history.record(counts, now)
  end

  # `GET /admin/api/history?mount=/live&range=day`: average and peak listeners per period. Without
  # `mount`, the whole server (for the server admin only). `range` is day, week, month, or year.
  private def handle_history(client : IO, params : HTTP::Params, headers : HTTP::Headers, head : Bool)
    access = require_admin(client, headers) || return
    mount = params["mount"]?.presence.try { |text| canonical_mount(text) }
    allowed = mount ? access.allows?(mount) : access.full?
    return send_admin_error(client, 404, "Stream not found") unless allowed
    chart = @history.chart(mount || ListenerHistory::TOTAL, params["range"]? || "day")
    send_admin_json(client, chart.to_json, head)
  rescue ex : ArgumentError
    send_admin_error(client, 400, ex.message || "Invalid range")
  end

  # Drops the listener history of *mount*, for example when an extension deletes a station.
  def forget_history(mount : String) : Nil
    @history.forget(mount)
  end
end
