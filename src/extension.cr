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

  # A listener asking to play a mount, before it is let in. *id* is the id the listener will have,
  # or nil for an HLS request, which is not a listener connection of its own.
  record ListenerRequest,
    id : Int64?,
    mount : String,
    address : String,
    headers : HTTP::Headers,
    started : Time::Instant = Time.instant do
    def user_agent : String
      headers["User-Agent"]? || ""
    end
  end

  # A listener that started playing.
  record ListenerConnection,
    id : Int64,
    mount : String,
    address : String,
    user_agent : String,
    country : String?

  # One finished HTTP request, for request logs. Listener requests finish when the listener leaves.
  record RequestRecord,
    address : String,
    user : String?,
    started_at : Time,
    method : String,
    target : String,
    version : String,
    status : Int32,
    bytes : Int64,
    referer : String?,
    user_agent : String?,
    duration : Time::Span

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

    # Protects a mount with a listener login: returns the realm to ask for credentials with (a 401
    # response), or nil when this extension does not protect the mount or the request may play it.
    def listener_challenge(request : ListenerRequest) : String?
    end

    # Called when a listener request that went through `listener_challenge` ends, whether it was let
    # in or not.
    def listener_closed(request : ListenerRequest) : Nil
    end

    def listener_connected(connection : ListenerConnection) : Nil
    end

    # Checks a source client login (*admin* for station updates such as metadata): true or false to
    # decide, nil to leave it to the configured source passwords. The first extension that decides wins.
    def source_login(mount : String, address : String, user : String, password : String, admin : Bool) : Bool?
    end

    # Called when *point* gets a source, including relays and fallback files (`point.source_protocol`).
    def source_connected(mount : String, point : MountPoint) : Nil
    end

    # Called after the source of *point* went away.
    def source_disconnected(mount : String, point : MountPoint) : Nil
    end

    # Called after the station details of *point* were changed through the API, such as whether it is
    # listed in directories.
    def station_updated(mount : String, point : MountPoint) : Nil
    end

    # Return false to keep HLS off for *mount*, for example when its listeners must be checked one by one.
    def hls_allowed?(mount : String) : Bool
      true
    end

    # The path of the HLS playlist of *mount*, shown in the dashboard; nil when there is none.
    def hls_url(mount : String) : String?
    end

    # How many listeners play *mount* over HLS, or nil when this extension serves no HLS for it. They
    # count in the listener history.
    def hls_listeners(mount : String) : Int32?
    end

    def recording_finished(file : Recording::Finished) : Nil
    end

    # Called after a configuration reload was applied, with the settings that need a restart.
    def reload_finished(restart_required : Array(String)) : Nil
    end

    # Return true to get `request_finished` for every HTTP request.
    def logs_requests? : Bool
      false
    end

    def request_finished(request : RequestRecord) : Nil
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
