require "openssl/hmac"
require "../plugin"
require "./listener_logins/htpasswd"

module Lurcast::Plugins
  # Private streams: listeners must sign in with a user name and password from an `htpasswd` file
  # before they can play a mount. Players send them with HTTP Basic authentication, usually from a
  # URL like `https://user:password@radio.example.com/private`.
  #
  # ```yaml
  # plugins:
  #   listener_logins:
  #     mounts:
  #       /private: /etc/lurcast/private.htpasswd
  #       "*": /etc/lurcast/listeners.htpasswd   # every other mount (optional)
  #     realm: My Radio   # shown by some players when they ask for the login
  # ```
  #
  # Admins manage the users from the dashboard or with `/admin/api/listener-logins`,
  # `POST /admin/listener-logins` and `POST /admin/listener-logins/remove`.
  class ListenerLogins < Plugin
    KEY      = "listener_logins"
    ALL      = "*"
    REMEMBER = 10.minutes

    class Settings
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter mounts : Hash(String, String) = {} of String => String
      getter realm : String = "Lurcast Listener"

      def validate! : Nil
        raise ArgumentError.new("plugins.listener_logins.mounts must list at least one mount") if mounts.empty?
        mounts.each do |mount, path|
          unless mount == ALL || (mount.starts_with?('/') && mount.size > 1)
            raise ArgumentError.new("plugins.listener_logins mount #{mount} must start with / (or be \"*\")")
          end
          raise ArgumentError.new("plugins.listener_logins file for #{mount} must not be empty") if path.strip.empty?
          raise ArgumentError.new("plugins.listener_logins file for #{mount} is a directory") if Dir.exists?(path)
        end
        raise ArgumentError.new("plugins.listener_logins realm must not be empty or contain quotes") if realm.empty? || realm.includes?('"')
      end
    end

    record UserList, mount : String, file : String, users : Array(String) do
      include JSON::Serializable
    end

    def self.build(settings : YAML::Any?, config : Config) : ListenerLogins?
      return unless settings
      parsed = Plugins.parse(Settings, KEY, settings)
      parsed.validate!
      new(parsed)
    end

    @files = {} of String => Htpasswd
    @verified = {} of String => Time::Instant
    @mutex = Mutex.new
    @key : Bytes = Random::Secure.random_bytes(32)

    def initialize(@settings : Settings)
      apply(@settings)
    end

    def name : String
      KEY
    end

    def config_reloaded(config : Config) : Nil
      settings = config.plugins[KEY]?.try { |section| Plugins.parse(Settings, KEY, section) }
      apply(settings || Settings.from_yaml("mounts: {}"))
    end

    # The password file that protects *mount*, if any.
    def file_for(mount : String) : Htpasswd?
      @mutex.synchronize { @files[mount]? || @files[ALL]? }
    end

    def listener_challenge(mount : String, headers : HTTP::Headers, address : String) : String?
      file = file_for(mount) || return
      realm = @mutex.synchronize { @settings.realm }
      user, password = basic_credentials(headers) || return realm
      verified?(file, user, password) ? nil : realm
    end

    def handle_request(server : IcecastServer, client : IO, request : HTTP::Request, address : String) : Bool
      case {request.method, request.path}
      when {"GET", "/admin/api/listener-logins"}
        list(server, client, request)
      when {"POST", "/admin/listener-logins"}
        change(server, client, request, remove: false)
      when {"POST", "/admin/listener-logins/remove"}
        change(server, client, request, remove: true)
      else
        return false
      end
      true
    end

    private def apply(settings : Settings) : Nil
      @mutex.synchronize do
        @settings = settings
        @files = settings.mounts.to_h do |mount, path|
          existing = @files[mount]?
          {mount, existing && existing.path == path ? existing : Htpasswd.new(path)}
        end
        @verified.clear
      end
    end

    # bcrypt is slow on purpose and HLS players send the login with every segment, so a login that
    # checked out is remembered for a while. The cache holds keyed digests that include the stored
    # hash, so a changed password or removed user stops working at once.
    private def verified?(file : Htpasswd, user : String, password : String) : Bool
      hash = file.hash_for(user) || return false
      digest = OpenSSL::HMAC.hexdigest(:sha256, @key, "#{file.path}\0#{user}\0#{hash}\0#{password}")
      now = Time.instant
      @mutex.synchronize do
        if (seen = @verified[digest]?) && now - seen < REMEMBER
          return true
        end
      end
      return false unless Htpasswd.matches?(hash, password)
      @mutex.synchronize do
        @verified.reject! { |_digest, seen| now - seen >= REMEMBER } if @verified.size >= 10_000
        @verified.clear if @verified.size >= 10_000
        @verified[digest] = now
      end
      true
    end

    private def basic_credentials(headers : HTTP::Headers) : Tuple(String, String)?
      scheme, _, token = (headers["Authorization"]? || return).partition(' ')
      return unless scheme.compare("Basic", case_insensitive: true) == 0
      user, separator, password = Base64.decode_string(token.strip).partition(':')
      {user, password} unless separator.empty?
    rescue Base64::Error
      nil
    end

    # `GET /admin/api/listener-logins?mount=/private`: the users who may listen to the mount.
    private def list(server : IcecastServer, client : IO, request : HTTP::Request) : Nil
      mount, file = target(server, client, request) || return
      body = UserList.new(mount, file.path, file.users).to_json
      server.respond(client, 200, body, "application/json", HTTP::Headers{"Cache-Control" => "no-store"})
    end

    # `POST /admin/listener-logins?mount=/private&user=anna&password=...` adds a user or changes the
    # password; `POST /admin/listener-logins/remove?mount=/private&user=anna` removes one.
    private def change(server : IcecastServer, client : IO, request : HTTP::Request, remove : Bool) : Nil
      mount, file = target(server, client, request) || return
      params = request.query_params
      user = params["user"]?.try(&.strip) || ""
      return error(server, client, 400, "user is required") if user.empty?
      if remove
        return error(server, client, 404, "No such user") unless file.delete(user)
        Log.info { "Removed listener login #{user} from #{mount}" }
        server.respond(client, 200, "Login removed")
      else
        password = params["password"]? || ""
        return error(server, client, 400, "The password must be at least 4 characters") if password.size < 4
        file.set(user, password)
        Log.info { "Saved listener login #{user} for #{mount}" }
        server.respond(client, 200, "Login saved")
      end
    rescue ex : ArgumentError
      error(server, client, 400, ex.message || "Invalid login")
    rescue ex : IO::Error
      Log.error { "Could not change the listener logins of #{mount}: #{ex.message}" }
      error(server, client, 500, "Could not save the file")
    end

    # The mount an admin request names and its password file. Logins limited to some mounts can
    # manage only files for their own mounts, not the shared `*` file.
    private def target(server : IcecastServer, client : IO, request : HTTP::Request) : Tuple(String, Htpasswd)?
      access = server.admin_login(request.headers)
      return server.challenge(client, "Lurcast Admin") unless access
      mount = request.query_params["mount"]?.try { |value| server.mount_name(value) }
      return error(server, client, 404, "Stream not found") unless mount && access.allows?(mount)
      own = @mutex.synchronize { @files[mount]? }
      file = own || (access.full? ? file_for(mount) : nil)
      return error(server, client, 404, "This stream has no listener logins") unless file
      {mount, file}
    end

    private def error(server : IcecastServer, client : IO, status : Int32, message : String) : Nil
      server.respond(client, status, {error: message}.to_json, "application/json", HTTP::Headers{"Cache-Control" => "no-store"})
    end
  end
end
