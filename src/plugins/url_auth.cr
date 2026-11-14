require "base64"
require "../plugin"

module Lurcast::Plugins
  # Checks source and listener logins with your own web service, like Icecast's URL authentication.
  # Lurcast posts a form to `url` and lets the client in when the response is 2xx and carries the
  # header `header: 1`:
  #
  # - `action=stream_auth` for a source client, or a station update when `admin=1`;
  # - `action=listener_add` for a listener (with `client`, the listener id, and `agent`), and
  #   `listener_remove` (with `duration` in seconds) when it leaves;
  # - `action=mount_add` and `mount_remove` when a mount gets or loses its source.
  #
  # Every request has `server`, `port`, `mount`, `user`, `pass` and `ip`. HLS is off while this
  # plugin is on, since HLS requests can't be checked one listener at a time.
  #
  # ```yaml
  # plugins:
  #   url_auth:
  #     url: https://auth.example.com/icecast
  #     header: icecast-auth-user   # the default
  #     timeout: 5                  # seconds (default 5)
  # ```
  class UrlAuth < Plugin
    register "url_auth"

    REALM = "Lurcast Listener"

    class Settings < Plugin::Settings
      getter url : String = ""
      getter header : String = "icecast-auth-user"
      getter timeout : Int32 = 5

      def enabled? : Bool
        @enabled && !url.empty?
      end

      def validate!(config : Config) : Nil
        invalid("url must be an http or https URL") unless Plugin.http_url?(url)
        invalid("header must not be empty") if header.strip.empty?
        invalid("timeout must be positive") unless timeout.positive?
      end
    end

    # Listeners let in, by id, so they are reported when they leave.
    @admitted = Set(Int64).new
    @mutex = Mutex.new

    def source_login(mount : String, address : String, user : String, password : String, admin : Bool) : Bool?
      params = params("stream_auth", mount, address, user, password)
      params["admin"] = admin ? "1" : "0"
      authorized?(params)
    end

    def listener_challenge(request : ListenerRequest) : String?
      id = request.id || return REALM
      user, password = credentials(request.headers)
      params = params("listener_add", request.mount, request.address, user, password)
      params["client"] = id.to_s
      params["agent"] = request.user_agent
      return REALM unless authorized?(params)
      @mutex.synchronize { @admitted << id }
      nil
    end

    def listener_closed(request : ListenerRequest) : Nil
      id = request.id || return
      return unless @mutex.synchronize { @admitted.delete(id) }
      user, password = credentials(request.headers)
      params = params("listener_remove", request.mount, request.address, user, password)
      params["client"] = id.to_s
      params["duration"] = (Time.instant - request.started).total_seconds.to_i.to_s
      spawn notify(params)
    end

    def source_connected(mount : String, point : MountPoint) : Nil
      notify(params("mount_add", mount))
    end

    def source_disconnected(mount : String, point : MountPoint) : Nil
      spawn notify(params("mount_remove", mount))
    end

    def hls_allowed?(mount : String) : Bool
      false
    end

    private def params(action : String, mount : String, address = "", user = "", password = "") : Hash(String, String)
      {
        "action" => action,
        "server" => config.hostname,
        "port"   => config.port.to_s,
        "mount"  => mount,
        "user"   => user,
        "pass"   => password,
        "ip"     => address,
      }
    end

    private def credentials(headers : HTTP::Headers) : Tuple(String, String)
      scheme, _, token = (headers["Authorization"]? || return {"", ""}).partition(' ')
      return {"", ""} unless scheme.compare("Basic", case_insensitive: true) == 0
      user, _, password = Base64.decode_string(token.strip).partition(':')
      {user, password}
    rescue Base64::Error
      {"", ""}
    end

    private def authorized?(params : Hash(String, String)) : Bool
      response = post(params) || return false
      response.status.success? && response.headers[settings.header]? == "1"
    end

    private def notify(params : Hash(String, String)) : Nil
      response = post(params)
      Log.warn { "Auth callback #{params["action"]} returned #{response.status_code}" } if response && !response.status.success?
    end

    private def post(params : Hash(String, String)) : HTTP::Client::Response?
      Plugin.post_form(settings.url, params, settings.timeout.seconds)
    rescue ex
      Log.warn { "Auth callback #{params["action"]} failed: #{ex.message}" }
      nil
    end
  end
end
