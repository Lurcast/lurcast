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
    register "listener_logins"
    dashboard "listener_logins/dashboard.js"

    ALL      = "*"
    REMEMBER = 10.minutes

    class Settings < Plugin::Settings
      getter mounts : Hash(String, String) = {} of String => String
      getter realm : String = "Lurcast Listener"

      def validate!(config : Config) : Nil
        invalid("mounts must list at least one mount") if mounts.empty?
        mounts.each do |mount, path|
          invalid("mount #{mount} must start with / (or be \"*\")") unless mount == ALL || (mount.starts_with?('/') && mount.size > 1)
          invalid("the file for #{mount} must not be empty") if path.strip.empty?
          invalid("the file for #{mount} is a directory") if Dir.exists?(path)
        end
        invalid("realm must not be empty or contain quotes") if realm.empty? || realm.includes?('"')
      end
    end

    record UserList, mount : String, file : String, users : Array(String) do
      include JSON::Serializable
    end

    @files = {} of String => Htpasswd
    @verified = {} of String => Time::Instant
    @mutex = Mutex.new
    @key : Bytes = Random::Secure.random_bytes(32)

    def initialize(@config : Config, @settings : Settings)
      reload(@settings)
    end

    # Takes the new password files; a removed section turns the logins off.
    def reload(settings : Settings?) : Nil
      @mutex.synchronize do
        @settings = settings if settings
        mounts = settings.try(&.mounts) || {} of String => String
        @files = mounts.to_h do |mount, path|
          existing = @files[mount]?
          {mount, existing && existing.path == path ? existing : Htpasswd.new(path)}
        end
        @verified.clear
      end
    end

    # The password file that protects *mount*, if any.
    def file_for(mount : String) : Htpasswd?
      @mutex.synchronize { @files[mount]? || @files[ALL]? }
    end

    def listener_challenge(request : ListenerRequest) : String?
      file = file_for(request.mount) || return
      realm = @mutex.synchronize { @settings.realm }
      user, password = basic_credentials(request.headers) || return realm
      verified?(file, user, password) ? nil : realm
    end

    # `GET /admin/api/listener-logins?mount=/private`: the users who may listen to the mount.
    @[Route("GET", "/admin/api/listener-logins", admin: true)]
    private def list(context : Context) : Nil
      mount, file = target(context)
      context.json(UserList.new(mount, file.path, file.users))
    end

    # `POST /admin/listener-logins?mount=/private&user=anna&password=...` adds a user or changes the
    # password.
    @[Route("POST", "/admin/listener-logins", admin: true)]
    private def save(context : Context) : Nil
      mount, file = target(context)
      user = context.param("user")
      password = context.params["password"]? || ""
      context.halt(400, "The password must be at least 4 characters") if password.size < 4
      changing(context, mount) { file.set(user, password) }
      Log.info { "Saved listener login #{user} for #{mount}" }
      context.text("Login saved")
    end

    # `POST /admin/listener-logins/remove?mount=/private&user=anna`.
    @[Route("POST", "/admin/listener-logins/remove", admin: true)]
    private def remove(context : Context) : Nil
      mount, file = target(context)
      user = context.param("user")
      context.halt(404, "No such user") unless changing(context, mount) { file.delete(user) }
      Log.info { "Removed listener login #{user} from #{mount}" }
      context.text("Login removed")
    end

    private def changing(context : Context, mount : String, &)
      yield
    rescue ex : ArgumentError
      context.halt(400, ex.message || "Invalid login")
    rescue ex : IO::Error
      Log.error { "Could not change the listener logins of #{mount}: #{ex.message}" }
      context.halt(500, "Could not save the file")
    end

    # The mount an admin request names and its password file. Logins limited to some mounts can
    # manage only files for their own mounts, not the shared `*` file.
    private def target(context : Context) : Tuple(String, Htpasswd)
      mount = context.mount
      own = @mutex.synchronize { @files[mount]? }
      file = own || (context.access.full? ? file_for(mount) : nil)
      context.halt(404, "This stream has no listener logins") unless file
      {mount, file}
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
  end
end
