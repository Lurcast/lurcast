require "log"
require "option_parser"
require "./lurcast"

module Lurcast
  module CLI
    # Parses arguments, loads the configuration, and runs the server until it is terminated.
    # *edition* names the build in `--version`; *setup* can register extensions before the server starts.
    def self.run(edition = "", &setup : IcecastServer, Config ->) : Nil
      config_path = "config.yml"
      OptionParser.parse do |parser|
        parser.banner = "Usage: lurcast [options]"
        parser.on("-c FILE", "--config=FILE", "Configuration file (default: config.yml)") { |path| config_path = path }
        parser.on("-v", "--version", "Print version") { puts [Lurcast::VERSION, edition.presence].compact.join(' '); exit }
        parser.on("-h", "--help", "Show help") { puts parser; exit }
      end

      config = Config.load(config_path)
      Log.setup(config.log_level)
      unless (defaults = config.default_password_settings).empty?
        Log.warn { "#{defaults.join(", ")} still use the default password; change them before exposing the server" }
      end
      Lurcast.configure_execution_context

      server = IcecastServer.new(config)
      server.config_path = config_path
      setup.call(server, config)
      Process.on_terminate { server.stop }
      # `kill -HUP` reloads config.yml (and reopens the access log) without dropping connections.
      Signal::HUP.trap { spawn server.reload_config } # ameba:disable Lint/SignalTrap
      server.start
    end
  end
end
