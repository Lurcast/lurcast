require "yaml"

module Lurcast
  abstract class Plugin < Extension
    # Raised by `Settings#validate!`; the message is reported with the plugin's section name.
    class InvalidSettings < Exception
    end

    # A plugin's section under `plugins:`. Plugins with settings subclass it and add getters with
    # defaults; unknown keys are an error. Every section takes `enabled: false`.
    class Settings
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter? enabled : Bool = true

      # Checks the settings against each other and the rest of the configuration. Call `invalid`
      # to reject them. May also normalize values.
      def validate!(config : Config) : Nil
      end

      protected def invalid(message : String) : NoReturn
        raise InvalidSettings.new(message)
      end
    end
  end
end
