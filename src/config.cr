require "log"
require "yaml"
require "./trusted_proxies"
require "uri"
require "./plugin"

class RelayConfig
  include YAML::Serializable
  include YAML::Serializable::Strict

  getter url : String
  getter mount : String
  getter username : String?
  getter password : String?
  getter retry_delay : Int32
  getter? on_demand : Bool

  def initialize(
    @url : String,
    @mount : String,
    @username : String? = nil,
    @password : String? = nil,
    @retry_delay : Int32 = 5,
    @on_demand : Bool = false,
  )
  end
end

class MountConfig
  include YAML::Serializable
  include YAML::Serializable::Strict

  property burst_size : Int32?
  property queue_size : Int32?
  property metadata_interval : Int32?
  property max_listeners : Int32?
  property max_listener_duration : Int32?
  property fallback : String?
  property fallback_override : Bool?
  property? fallback_when_full : Bool = false
  property username : String?
  property password : String?
  property? hidden : Bool = false
  property intro : String?
  # Record every source on this mount to `recordings_dir`.
  property? record : Bool = false

  def initialize(
    @burst_size : Int32? = nil,
    @queue_size : Int32? = nil,
    @metadata_interval : Int32? = nil,
    @max_listeners : Int32? = nil,
    @max_listener_duration : Int32? = nil,
    @fallback : String? = nil,
    @fallback_override : Bool? = nil,
    @fallback_when_full : Bool = false,
    @username : String? = nil,
    @password : String? = nil,
    @hidden : Bool = false,
    @intro : String? = nil,
    @record : Bool = false,
  )
  end
end

class Config
  include YAML::Serializable
  include YAML::Serializable::Strict

  property host : String = "0.0.0.0"
  property port : Int32 = 8000
  DEFAULT_PASSWORD = "hackme"

  property admin_password : String = DEFAULT_PASSWORD
  property source_password : String = DEFAULT_PASSWORD
  property max_listeners : Int32 = 1000
  property max_sources : Int32 = 10
  # Concurrent non-listener connections (sources, API and admin requests, unfinished headers) per address.
  property max_connections_per_ip : Int32 = 5
  # Concurrent listeners per address; unset means unlimited, since many players can share one NAT address.
  property max_listeners_per_ip : Int32?
  property burst_size : Int32 = 65_536
  property queue_size : Int32 = 524_288
  property metadata_interval : Int32 = 8192
  @[YAML::Field(key: "buffer_size", ignore_serialize: true)]
  @legacy_buffer_size : Int32?
  property timeout : Int32 = 30
  property header_timeout : Int32?
  property source_timeout : Int32?
  property log_level : Log::Severity = Log::Severity::Info
  property allowed_origins : Array(String) = ["*"]
  property rate_limit : Int32 = 100
  property rate_limit_window : Int32 = 60
  property tls_port : Int32?
  property tls_cert : String?
  property tls_key : String?
  property shoutcast_port : Int32?
  property shoutcast_mount : String = "/stream"
  property shoutcast_mounts : Hash(Int32, String) = {} of Int32 => String
  property uvox_cipher_key : String = "foobar"
  property hostname : String = "localhost"
  @public_url : String? = nil
  property admin_email : String = ""
  @fallbacks : Hash(String, String) = {} of String => String
  @[YAML::Field(ignore: true)]
  @fallbacks_mutex = Mutex.new
  property? fallback_override : Bool = true
  @mounts : Hash(String, MountConfig) = {} of String => MountConfig
  @[YAML::Field(ignore: true)]
  @mounts_mutex = Mutex.new
  property webroot : String?
  property fallback_file_bitrate : Int32 = 128
  property relays : Array(RelayConfig) = [] of RelayConfig
  property relay_username : String = "relay"
  property relay_password : String = DEFAULT_PASSWORD
  property master_url : String?
  property master_username : String = "relay"
  property master_password : String?
  property master_update_interval : Int32 = 120
  property? relays_on_demand : Bool = false
  property song_history_size : Int32 = 10
  # Where Lurcast keeps its own state: the ban list and the listener history. Unset keeps them in memory.
  property data_dir : String?
  property recordings_dir : String?
  # Start a new recording file after this many minutes (MP3 and AAC only); 0 keeps one file per connection.
  property record_split_minutes : Int32 = 0
  # Reverse proxies (addresses or CIDR ranges) whose X-Forwarded-For header gives the client address.
  property trusted_proxies : Array(String) = [] of String
  # Settings for optional editions (for example `hosting:`); the core server ignores them.
  property hosting : YAML::Any?
  # Settings for the plugins built into the server (`acme`, `listener_logins`, `transcode`, ...), by name.
  property plugins : Hash(String, YAML::Any) = {} of String => YAML::Any

  def initialize
  end

  # Base URL for stream links in playlists and status output. Without `public_url`, it follows
  # `hostname` and `port`.
  def public_url : String
    @public_url || "http://#{@hostname}:#{@port}"
  end

  def public_url=(@public_url : String?)
  end

  def self.load(path = "config.yml") : Config
    config = begin
      File.open(path) { |file| from_yaml(file) }
    rescue File::NotFoundError
      new
    end
    config.apply_env
    config.validate!
    config
  rescue ex : YAML::ParseException
    raise ArgumentError.new("Invalid #{path}: #{ex.message}")
  end

  def apply_env
    apply_string_env host, admin_password, source_password, tls_cert, tls_key, shoutcast_mount,
      uvox_cipher_key, hostname, public_url, admin_email, webroot, relay_username, relay_password,
      master_url, master_username, master_password, recordings_dir, data_dir
    apply_int_env port, max_listeners, max_sources, max_connections_per_ip, max_listeners_per_ip, queue_size,
      metadata_interval, timeout, header_timeout, source_timeout, rate_limit, rate_limit_window, tls_port, shoutcast_port,
      fallback_file_bitrate, master_update_interval
    @burst_size = env_int("BURST_SIZE") || env_int("BUFFER_SIZE") || @burst_size
    @log_level = env("LOG_LEVEL").try { |value| Log::Severity.parse(value) } || @log_level
    @allowed_origins = env("ALLOWED_ORIGINS").try { |origins| origins.split(',').map!(&.strip) } || @allowed_origins
    @fallback_override = env_bool("FALLBACK_OVERRIDE", @fallback_override)
    @relays_on_demand = env_bool("RELAYS_ON_DEMAND", @relays_on_demand)
  end

  def validate!
    raise ArgumentError.new("port must be between 1 and 65535") unless 1 <= @port <= 65_535
    raise ArgumentError.new("source_password must not be empty") if @source_password.empty?
    raise ArgumentError.new("admin_password must not be empty") if @admin_password.empty?
    limits = {@max_listeners, @max_sources, @max_connections_per_ip, @burst_size, @queue_size,
              @metadata_interval, @timeout, @rate_limit, @rate_limit_window, @master_update_interval,
              @fallback_file_bitrate}
    raise ArgumentError.new("limits must be positive") unless limits.all?(&.positive?)
    raise ArgumentError.new("timeouts must be positive") unless [@header_timeout, @source_timeout].compact.all?(&.positive?)
    raise ArgumentError.new("max_listeners_per_ip must be positive") if @max_listeners_per_ip.try { |value| !value.positive? }
    raise ArgumentError.new("burst_size must not exceed queue_size") if @burst_size > @queue_size
    validate_optional_port!(@tls_port, "tls_port")
    validate_optional_port!(@shoutcast_port, "shoutcast_port")
    validate_unique!([@port, @tls_port, @shoutcast_port].compact, "listener ports must be unique")
    validate_tls!
    validate_mount!(@shoutcast_mount, "shoutcast_mount")
    raise ArgumentError.new("uvox_cipher_key must contain 1 to 16 bytes") unless 1 <= @uvox_cipher_key.bytesize <= 16
    @shoutcast_mounts.each do |sid, mount|
      raise ArgumentError.new("SHOUTcast stream IDs must be positive") unless sid.positive?
      validate_mount!(mount, "SHOUTcast mounts")
    end
    validate_unique!(@shoutcast_mounts.values, "SHOUTcast mounts must be unique")
    @fallbacks.each do |mount, fallback|
      validate_mount!(mount, "fallback mounts")
      validate_mount!(fallback, "fallback mounts")
      raise ArgumentError.new("fallback mount must differ from its source mount") if mount == fallback
    end
    @mounts.each { |mount, settings| validate_mount_settings!(mount, settings) }
    raise ArgumentError.new("song_history_size must not be negative") if @song_history_size.negative?
    validate_features!
    Lurcast::Plugins.validate!(self)
    if webroot = @webroot
      raise ArgumentError.new("webroot must be a directory") unless Dir.exists?(webroot)
    end
    @relays.each do |relay|
      validate_http_url!(relay.url, "relay URL")
      validate_mount!(relay.mount, "relay mount")
      raise ArgumentError.new("relay retry_delay must be positive") unless relay.retry_delay.positive?
      raise ArgumentError.new("relay username and password must be configured together") unless relay.username.nil? == relay.password.nil?
    end
    validate_unique!(@relays.map(&.mount), "relay mounts must be unique")
    raise ArgumentError.new("relay credentials must not be empty") if @relay_username.empty? || @relay_password.empty?
    if master_url = @master_url
      validate_http_url!(master_url, "master_url")
      raise ArgumentError.new("master credentials are required") if @master_username.empty? || @master_password.presence.nil?
    end
    validate_http_url!(public_url, "public_url")
  end

  def shoutcast_mount_for(sid : Int32) : String?
    @shoutcast_mounts[sid]? || (@shoutcast_mount if sid == 1)
  end

  # A snapshot of the per-mount settings.
  def mounts : Hash(String, MountConfig)
    @mounts_mutex.synchronize { @mounts.dup }
  end

  def mounts=(mounts : Hash(String, MountConfig))
    @mounts_mutex.synchronize { @mounts = mounts.dup }
  end

  def mount_settings(mount : String) : MountConfig?
    @mounts_mutex.synchronize { @mounts[mount]? }
  end

  # Adds or replaces one mount's settings at runtime, validating them first.
  def set_mount(mount : String, settings : MountConfig)
    validate_mount_settings!(mount, settings)
    @mounts_mutex.synchronize { @mounts[mount] = settings }
  end

  def remove_mount(mount : String) : MountConfig?
    @mounts_mutex.synchronize { @mounts.delete(mount) }
  end

  def burst_size_for(mount : String) : Int32
    mount_settings(mount).try(&.burst_size) || @burst_size
  end

  # Names of the password settings still at the built-in default, which anyone can guess.
  def default_password_settings : Array(String)
    {
      "admin_password"  => @admin_password,
      "source_password" => @source_password,
      "relay_password"  => @relay_password,
    }.compact_map { |name, value| name if value == DEFAULT_PASSWORD }
  end

  def header_timeout_for : Int32
    @header_timeout || @timeout
  end

  def source_timeout_for : Int32
    @source_timeout || @timeout
  end

  def queue_size_for(mount : String) : Int32
    mount_settings(mount).try(&.queue_size) || @queue_size
  end

  def metadata_interval_for(mount : String, source_interval : Int32? = nil) : Int32
    mount_settings(mount).try(&.metadata_interval) || source_interval || @metadata_interval
  end

  def max_listeners_for(mount : String) : Int32?
    mount_settings(mount).try(&.max_listeners)
  end

  def max_listener_duration_for(mount : String) : Int32?
    mount_settings(mount).try(&.max_listener_duration)
  end

  # The username and password a source must present for *mount*; per-mount credentials replace the global ones.
  def source_credentials_for(mount : String) : Tuple(String, String)
    settings = mount_settings(mount)
    {settings.try(&.username) || "source", settings.try(&.password) || @source_password}
  end

  def hidden?(mount : String) : Bool
    mount_settings(mount).try(&.hidden?) || false
  end

  def intro_for(mount : String) : String?
    mount_settings(mount).try(&.intro)
  end

  def fallback_for(mount : String) : String?
    @fallbacks_mutex.synchronize { @fallbacks[mount]? } || mount_settings(mount).try(&.fallback)
  end

  def set_fallback(mount : String, fallback : String)
    @fallbacks_mutex.synchronize { @fallbacks[mount] = fallback }
  end

  # Removes a fallback set at runtime. A fallback from the configuration file applies again.
  def clear_fallback(mount : String)
    @fallbacks_mutex.synchronize { @fallbacks.delete(mount) }
  end

  def fallback_override_for?(mount : String) : Bool
    value = mount_settings(mount).try(&.fallback_override)
    value.nil? ? @fallback_override : value
  end

  def fallback_when_full?(mount : String) : Bool
    mount_settings(mount).try(&.fallback_when_full?) || false
  end

  def fallback_count : Int32
    @fallbacks_mutex.synchronize { @fallbacks.size } + mounts.count { |_mount, settings| !settings.fallback.nil? }
  end

  def fallback_target?(mount : String) : Bool
    @fallbacks_mutex.synchronize { @fallbacks.has_value?(mount) } || mounts.any? { |_source, settings| settings.fallback == mount }
  end

  protected def after_initialize
    if legacy = @legacy_buffer_size
      @burst_size = legacy
    end
  end

  private def validate_features!
    if dir = @recordings_dir
      raise ArgumentError.new("recordings_dir must be a directory") if File.exists?(dir) && !Dir.exists?(dir)
    end
    raise ArgumentError.new("record_split_minutes must not be negative") if @record_split_minutes.negative?
    @trusted_proxies.each do |entry|
      raise ArgumentError.new("invalid trusted_proxies entry #{entry}") unless TrustedProxies.valid?(entry)
    end
  end

  def validate_mount_settings!(mount : String, settings : MountConfig)
    validate_mount!(mount, "mounts")
    limits = [settings.burst_size, settings.queue_size, settings.metadata_interval,
              settings.max_listeners, settings.max_listener_duration].compact
    raise ArgumentError.new("mount #{mount} limits must be positive") unless limits.all?(&.positive?)
    burst_size = settings.burst_size || @burst_size
    queue_size = settings.queue_size || @queue_size
    raise ArgumentError.new("mount #{mount} burst_size must not exceed queue_size") if burst_size > queue_size
    if fallback = settings.fallback
      validate_mount!(fallback, "mount fallback")
      raise ArgumentError.new("mount fallback must differ from its source mount") if mount == fallback
    end
    if settings.username && settings.password.nil?
      raise ArgumentError.new("mount #{mount} username requires a password")
    end
    if settings.username.try(&.empty?) || settings.password.try(&.empty?)
      raise ArgumentError.new("mount #{mount} source credentials must not be empty")
    end
    if settings.intro && @webroot.nil?
      raise ArgumentError.new("mount #{mount} intro requires webroot")
    end
    if settings.record? && @recordings_dir.nil?
      raise ArgumentError.new("mount #{mount} record requires recordings_dir")
    end
  end

  def record?(mount : String) : Bool
    mount_settings(mount).try(&.record?) || false
  end

  # Settings that only take effect at startup.
  RESTART_SETTINGS = %w[host port tls_port shoutcast_port data_dir master_url master_username master_password relays_on_demand master_update_interval]

  # Copies every setting from *other*, a freshly loaded and validated configuration, into this one,
  # so code holding this object sees the new values. Runtime fallbacks are replaced by the file's.
  # Returns the settings that changed but need a restart to take effect.
  def reload_from(other : Config) : Array(String)
    restart = [] of String
    {% for name in RESTART_SETTINGS %}
      restart << {{ name }} unless @{{ name.id }} == other.@{{ name.id }}
    {% end %}
    {% for ivar in @type.instance_vars %}
      {% unless (RESTART_SETTINGS + %w[fallbacks_mutex mounts_mutex mounts fallbacks]).includes?(ivar.name.stringify) %}
        @{{ ivar.name }} = other.@{{ ivar.name }}
      {% end %}
    {% end %}
    fallbacks = other.@fallbacks_mutex.synchronize { other.@fallbacks.dup }
    @fallbacks_mutex.synchronize { @fallbacks = fallbacks }
    self.mounts = other.mounts
    restart
  end

  private def validate_optional_port!(port : Int32?, name : String)
    raise ArgumentError.new("#{name} must be between 1 and 65535") if port && !(1 <= port <= 65_535)
  end

  private def validate_unique!(values : Array(T), message : String) forall T
    size = values.size
    raise ArgumentError.new(message) unless values.uniq!.size == size
  end

  private def validate_tls!
    port, cert, key = @tls_port, @tls_cert, @tls_key
    return unless port || cert || key
    unless port && cert && key
      raise ArgumentError.new("tls_port, tls_cert, and tls_key must be configured together")
    end
    raise ArgumentError.new("TLS certificate not found: #{cert}") unless File.file?(cert)
    raise ArgumentError.new("TLS key not found: #{key}") unless File.file?(key)
  end

  private def env(name : String) : String?
    ENV["LURCAST_#{name}"]? || ENV["ICECAST_#{name}"]?
  end

  private macro apply_string_env(*names)
    {% for name in names %}
      @{{ name.id }} = env({{ name.stringify.upcase }}) || @{{ name.id }}
    {% end %}
  end

  private macro apply_int_env(*names)
    {% for name in names %}
      @{{ name.id }} = env_int({{ name.stringify.upcase }}) || @{{ name.id }}
    {% end %}
  end

  private def env_int(name : String) : Int32?
    env(name).try(&.to_i)
  end

  private def env_bool(name : String, current : Bool) : Bool
    value = env(name)
    return current unless value
    case value.downcase
    when "1", "true", "yes" then true
    when "0", "false", "no" then false
    else                         raise ArgumentError.new("LURCAST_#{name} must be true or false")
    end
  end

  private def validate_http_url!(value : String, name : String)
    uri = URI.parse(value)
    raise ArgumentError.new("#{name} must use http or https and include a host") unless uri.scheme.in?("http", "https") && uri.host.presence
  end

  private def validate_mount!(mount : String, name : String)
    raise ArgumentError.new("#{name} must start with /") unless mount.starts_with?('/')
  end
end
