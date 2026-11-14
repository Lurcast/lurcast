require "http/headers"
require "http/request"

module Lurcast
  # A finished listener connection, reported to extensions when the listener disconnects.
  record ListenerSession,
    id : Int64,
    mount : String,
    address : String,
    user_agent : String,
    started_at : Time,
    duration : Time::Span,
    bytes_sent : Int64,
    unbilled_bytes : Int64,
    country : String? = nil

  # Extension points for optional editions. Every method has a no-op default; the server
  # calls them from connection fibers, so implementations must be safe to call concurrently.
  abstract class Extension
    # Called once, before the server accepts connections.
    def start(server : IcecastServer) : Nil
    end

    def stop : Nil
    end

    # Handles a request the core does not route. Return true when the extension wrote a response.
    def handle_request(server : IcecastServer, client : IO, request : HTTP::Request, address : String) : Bool
      false
    end

    # Returns a reason to refuse a source for *mount*, or nil to allow it.
    def source_rejection(mount : String, headers : HTTP::Headers) : String?
    end

    # Returns a reason to refuse a new listener on *mount*, or nil to allow it.
    def listener_rejection(mount : String) : String?
    end

    def listener_finished(session : ListenerSession) : Nil
    end

    # Returns the ISO 3166-1 country code for a listener's address, or nil. The first extension that
    # answers is used; the country is shown in the dashboard and passed to webhooks and sessions.
    def listener_country(address : String) : String?
    end

    # The name of the location data this extension provides, shown in the dashboard; nil for none.
    def locations_source : String?
    end

    # Grants an admin login limited to some mounts: returns the mounts *user* with *password* may
    # manage, or nil to refuse. The server admin (`admin` and `admin_password`) is checked first.
    def admin_login(user : String, password : String) : Array(String)?
    end

    # Called after the configuration file was reloaded into *config* (the same object as before).
    def config_reloaded(config : Config) : Nil
    end

    # Called when the song on *mount* changes, with the listener count at that moment.
    def song_changed(mount : String, song : String, listeners : Int32, at : Time) : Nil
    end

    # Protects *mount* with a listener login: returns the realm to ask for credentials with (a 401
    # response), or nil when this extension does not protect the mount or the credentials are right.
    def listener_challenge(mount : String, headers : HTTP::Headers, address : String) : String?
    end

    # Called when a SHOUTcast 2 source sends artwork for *mount*: the station logo, or the cover of
    # the song playing when *playing* is true. An empty *data* removes it.
    def artwork_received(mount : String, playing : Bool, content_type : String, data : Bytes) : Nil
    end

    # The path of the cover art for *mount*, listed in status output; nil when there is none.
    def artwork_url(mount : String) : String?
    end
  end
end
