require "http/client"
require "log"
require "uri"
require "yaml"
require "./extension"
require "./plugin/settings"
require "./plugin/context"

module Lurcast
  # A feature that ships in the binary but stays apart from the core server. Each plugin is a
  # subclass in its own file under `src/plugins/`, reads its own section under `plugins:` in the
  # configuration, and works through the `Extension` hooks and the server's public methods.
  #
  # ```
  # class Greeter < Plugin
  #   register "greeter" # the section under `plugins:`; `enabled_by_default: true` builds it without one
  #
  #   class Settings < Plugin::Settings
  #     getter greeting : String = "Hello"
  #
  #     def validate!(config : Config) : Nil
  #       invalid("greeting must not be empty") if greeting.empty?
  #     end
  #   end
  #
  #   @[Route("GET", "/hello")]
  #   private def hello(context : Context) : Nil
  #     context.text("#{settings.greeting}, #{context.address}")
  #   end
  # end
  # ```
  #
  # A subclass gets, from `register` and `inherited`:
  #
  # - `KEY`, `Log` (`lurcast.plugins.<key>`) and `#name`;
  # - `.build`, which parses and checks the section and returns nil when it turns the plugin off;
  # - `#settings`, typed as the plugin's own `Settings` class (`Plugin::Settings` when it has none);
  # - `#handle_request`, which runs the methods marked with `@[Route]`;
  # - `#config_reloaded`, which parses the section again and passes it to `#reload`.
  abstract class Plugin < Extension
    # Marks a method that answers requests: `@[Route("POST", "/admin/thing", admin: true)]`.
    #
    # - The method takes a `Context`. `GET` routes also answer `HEAD`.
    # - `prefix: true` matches every path that starts with the given one.
    # - `admin: true` asks for an admin login first and puts it in `Context#access`.
    annotation Route
    end

    abstract def name : String
    abstract def config : Config

    # Called after a configuration reload with the plugin's checked settings, or nil when the
    # section was removed or turns the plugin off. Invalid settings are logged and never get here.
    def reload(settings) : Nil
    end

    # Whether *value* is an http or https URL with a host.
    def self.http_url?(value : String) : Bool
      uri = URI.parse(value)
      uri.scheme.in?("http", "https") && !uri.host.presence.nil?
    end

    # Posts *params* as a form to *url* and returns the response (its body unread).
    def self.post_form(url : String, params : Hash(String, String), timeout : Time::Span) : HTTP::Client::Response
      uri = URI.parse(url)
      HTTP::Client.new(uri) do |client|
        client.connect_timeout = timeout
        client.read_timeout = timeout
        client.post(uri.request_target, form: params) { |response| response }
      end
    end

    # Writes *content* to *path* through a temporary file, so readers never see half a file.
    def self.write_file(path : String, content : String | Bytes, perm = 0o600) : Nil
      directory = File.dirname(path)
      Dir.mkdir_p(directory)
      temporary = File.join(directory, ".#{File.basename(path)}.#{Random::Secure.hex(4)}.tmp")
      begin
        File.write(temporary, content, perm: perm)
        File.rename(temporary, path)
      rescue ex
        File.delete?(temporary)
        raise ex
      end
    end

    # Names the plugin's configuration section. With `enabled_by_default: true` the plugin is built
    # without a section, and `enabled: false` turns it off; otherwise the section turns it on.
    macro register(key, *, enabled_by_default = false)
      KEY = {{ key }}
      Log = ::Log.for("lurcast.plugins.{{ key.id }}")

      def self.key : String
        KEY
      end

      def self.enabled_by_default? : Bool
        {{ enabled_by_default }}
      end
    end

    macro inherited
      getter config : Config
      getter settings : Settings

      def initialize(@config : Config, @settings : Settings)
      end

      def name : String
        KEY
      end

      # Builds the plugin from its section, or returns nil when the section turns it off. Raises
      # `ArgumentError`, naming the section, when the settings are invalid.
      def self.build(section : YAML::Any?, config : Config) : self?
        settings = settings_for(section, config) || return
        new(config, settings)
      end

      # The checked settings in *section*, or nil when it turns the plugin off.
      def self.settings_for(section : YAML::Any?, config : Config) : Settings?
        section = nil if section.try(&.raw).nil?
        return unless section || enabled_by_default?
        settings = section ? Settings.from_yaml(section.to_yaml) : Settings.from_yaml("{}")
        return unless settings.enabled?
        settings.validate!(config)
        settings
      rescue ex : YAML::ParseException | ::Lurcast::Plugin::InvalidSettings
        raise ArgumentError.new("Invalid plugins.#{KEY}: #{ex.message}")
      end

      def config_reloaded(config : Config) : Nil
        settings = begin
          self.class.settings_for(config.plugins[KEY]?, config)
        rescue ex : ArgumentError
          Log.error { "#{ex.message}; keeping the current settings" }
          return
        end
        @config = config
        reload(settings)
      end

      def handle_request(server : IcecastServer, client : IO, request : HTTP::Request, address : String) : Bool
        method = request.method == "HEAD" ? "GET" : request.method
        path = request.path
        \{% for method in @type.methods %}
          \{% for route in method.annotations(::Lurcast::Plugin::Route) %}
            \{% raise "#{@type}##{method.name}: @[Route] needs a method and a path" unless route[0] && route[1] %}
            if method == \{{ route[0] }} && \{% if route[:prefix] %} path.starts_with?(\{{ route[1] }}) \{% else %} path == \{{ route[1] }} \{% end %}
              context = ::Lurcast::Plugin::Context.new(server, client, request, address)
              context.run(admin: \{{ route[:admin] == true }}) { \{{ method.name.id }}(context) }
              return true
            end
          \{% end %}
        \{% end %}
        false
      end
    end
  end

  # The plugins built into this binary.
  module Plugins
    # Runs the block once for every plugin class, checking at compile time that each one calls
    # `register` with a key no other plugin uses.
    macro each_plugin(&block)
      {% plugins = Plugin.all_subclasses.reject(&.abstract?) %}
      {% keys = {} of StringLiteral => TypeNode %}
      {% for plugin in plugins %}
        {% raise "#{plugin} must call `register` with its section name" unless plugin.has_constant?(:KEY) %}
        {% key = plugin.constant(:KEY) %}
        {% raise "#{plugin} and #{keys[key]} both register #{key}" if keys[key] %}
        {% keys[key] = plugin %}
      {% end %}
      {% for plugin in plugins %}
        {{ block.args[0].id }} = {{ plugin }}
        {{ block.body }}
      {% end %}
    end

    # The section names of the plugins built in. Settings for any other name are an error.
    def self.keys : Array(String)
      keys = [] of String
      each_plugin { |plugin| keys << plugin.key }
      keys
    end

    # Builds every plugin that *config* turns on.
    def self.build(config : Config) : Array(Plugin)
      config.migrate_legacy_settings!
      plugins = [] of Plugin
      each_plugin do |plugin|
        if built = plugin.build(config.plugins[plugin.key]?, config)
          plugins << built
        end
      end
      plugins
    end

    def self.validate!(config : Config) : Nil
      unknown = config.plugins.keys - keys
      raise ArgumentError.new("unknown plugins: #{unknown.join(", ")}") unless unknown.empty?
      each_plugin { |plugin| plugin.settings_for(config.plugins[plugin.key]?, config) }
    end
  end
end

require "./plugins/*"
