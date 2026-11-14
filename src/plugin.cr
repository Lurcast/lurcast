require "yaml"
require "./extension"

module Lurcast
  # A feature that ships in the binary but stays apart from the core server. Each plugin lives in its
  # own directory under `src/plugins/`, reads its own section under `plugins:` in the configuration,
  # and works through the `Extension` hooks and the server's public methods, like an edition does.
  #
  # A plugin class names its section with `KEY` and builds itself with `self.build`, which returns
  # nil when the section turns it off. Building also validates the section: it raises
  # `ArgumentError` for bad settings, so `Config.validate!` can report them before the server starts.
  abstract class Plugin < Extension
    # The plugin's section under `plugins:`, also shown in the dashboard.
    abstract def name : String
  end

  module Plugins
    # The plugins built into this binary, by section name. Settings for any other name are an error.
    def self.keys : Array(String)
      {% begin %}
        [{% for plugin in Plugin.all_subclasses.reject(&.abstract?) %} {{ plugin }}::KEY, {% end %}] of String
      {% end %}
    end

    # Builds every plugin that *config* turns on.
    def self.build(config : Config) : Array(Plugin)
      plugins = [] of Plugin
      {% for plugin in Plugin.all_subclasses.reject(&.abstract?) %}
        if built = {{ plugin }}.build(config.plugins[{{ plugin }}::KEY]?, config)
          plugins << built
        end
      {% end %}
      plugins
    end

    # Reads a plugin section into *type*, a YAML::Serializable class. Errors name the plugin.
    def self.parse(type : T.class, key : String, settings : YAML::Any) : T forall T
      type.from_yaml(settings.to_yaml)
    rescue ex : YAML::ParseException
      raise ArgumentError.new("Invalid plugins.#{key}: #{ex.message}")
    end

    def self.validate!(config : Config) : Nil
      unknown = config.plugins.keys - keys
      raise ArgumentError.new("unknown plugins: #{unknown.join(", ")}") unless unknown.empty?
      build(config)
    end
  end
end

require "./plugins/*"
