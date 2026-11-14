require "http/client"
require "json"
require "openssl/hmac"
require "uuid"
require "../plugin"

module Lurcast::Plugins
  # Sends server events as JSON POST requests to the configured URLs:
  #
  #   {"event": "song.changed", "id": "2f1c…", "at": "2026-11-13T22:01:14Z", "server": "https://radio.example",
  #    "data": {"mount": "/live", "song": "Artist - Title", "listeners": 42}}
  #
  # Each request carries `X-Lurcast-Event`, `X-Lurcast-Delivery` (the id), and, with a secret,
  # `X-Lurcast-Signature: sha256=<hex HMAC-SHA256 of the body>`. A response other than 2xx is
  # retried twice, after 2 and 10 seconds. Each endpoint has its own bounded queue, so a slow
  # receiver never delays streaming; events that do not fit are dropped and logged.
  #
  # ```yaml
  # plugins:
  #   webhooks:
  #     timeout: 5   # seconds (default 5)
  #     endpoints:
  #       - url: https://example.com/hooks/radio
  #         events: [source.connected, song.changed]   # optional; default: all but listener events
  #         secret: s3cret                             # optional; signs each body
  # ```
  class Webhooks < Plugin
    register "webhooks"

    EVENTS         = %w[source.connected source.disconnected song.changed listener.connected listener.disconnected recording.finished config.reloaded]
    DEFAULT_EVENTS = EVENTS.reject(&.starts_with?("listener."))
    QUEUE_SIZE     = 1024
    RETRY_DELAYS   = [2.seconds, 10.seconds]

    # One URL to send events to.
    class Endpoint
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter url : String
      # Event names to send; without it, every event except the listener ones.
      getter events : Array(String)?
      # Signs each body with HMAC-SHA256 in `X-Lurcast-Signature` when set.
      getter secret : String?

      def initialize(@url : String, @events : Array(String)? = nil, @secret : String? = nil)
      end

      def wants?(event : String) : Bool
        (@events || DEFAULT_EVENTS).includes?(event)
      end
    end

    class Settings < Plugin::Settings
      getter endpoints : Array(Endpoint) = [] of Endpoint
      getter timeout : Int32 = 5

      def enabled? : Bool
        @enabled && !endpoints.empty?
      end

      def validate!(config : Config) : Nil
        endpoints.each do |endpoint|
          invalid("#{endpoint.url} must be an http or https URL") unless Plugin.http_url?(endpoint.url)
          unknown = (endpoint.events || [] of String) - EVENTS
          invalid("unknown events: #{unknown.join(", ")}") unless unknown.empty?
          invalid("secret must not be empty") if endpoint.secret.try(&.empty?)
        end
        invalid("timeout must be positive") unless timeout.positive?
      end
    end

    # The JSON body of every delivery: the event's name, a unique id, when it happened, which server
    # sent it, and the event's own data.
    record Envelope(T), event : String, id : String, at : Time, server : String, data : T do
      include JSON::Serializable
    end

    # One record per event. `EVENT` is the name used in the configuration and `X-Lurcast-Event`.
    record SourceConnected, mount : String, protocol : SourceProtocol, content_type : String, bitrate : Int32, name : String, genre : String do
      include JSON::Serializable
      EVENT = "source.connected"
    end

    record SourceDisconnected, mount : String, duration_seconds : Int64, peak_listeners : Int32 do
      include JSON::Serializable
      EVENT = "source.disconnected"
    end

    record SongChanged, mount : String, song : String, listeners : Int32 do
      include JSON::Serializable
      EVENT = "song.changed"
    end

    @[JSON::Serializable::Options(emit_nulls: true)]
    record ListenerConnected, mount : String, id : Int64, address : String, user_agent : String, country : String? do
      include JSON::Serializable
      EVENT = "listener.connected"
    end

    @[JSON::Serializable::Options(emit_nulls: true)]
    record ListenerDisconnected,
      mount : String,
      id : Int64,
      address : String,
      user_agent : String,
      country : String?,
      duration_seconds : Int64,
      bytes_sent : Int64 do
      include JSON::Serializable
      EVENT = "listener.disconnected"
    end

    record RecordingFinished, mount : String, path : String, file : String, bytes : Int64, started_at : Time, duration_seconds : Int64 do
      include JSON::Serializable
      EVENT = "recording.finished"
    end

    record ConfigReloaded, restart_required : Array(String) do
      include JSON::Serializable
      EVENT = "config.reloaded"
    end

    private record Delivery, id : String, event : String, body : String

    private class Target
      getter endpoint : Endpoint
      getter timeout : Time::Span
      getter queue = Channel(Delivery).new(QUEUE_SIZE)
      getter dropped = Atomic(Int64).new(0_i64)

      def initialize(@endpoint : Endpoint, @timeout : Time::Span)
      end
    end

    @targets = [] of Target
    @mutex = Mutex.new

    def start(server : IcecastServer) : Nil
      targets = start_targets(settings)
      @mutex.synchronize { @targets = targets }
    end

    def stop : Nil
      targets = @mutex.synchronize { @targets.tap { @targets = [] of Target } }
      targets.each(&.queue.close)
    end

    def reload(settings : Settings?) : Nil
      started = settings ? start_targets(settings) : [] of Target
      old = @mutex.synchronize do
        @settings = settings if settings
        @targets.tap { @targets = started }
      end
      old.each(&.queue.close)
    end

    # Queues *data*, one of the event records above, for every endpoint subscribed to its event.
    def emit(data : T) : Nil forall T
      event = T::EVENT
      targets = @mutex.synchronize { @targets.select(&.endpoint.wants?(event)) }
      return if targets.empty?

      id = UUID.random.to_s
      delivery = Delivery.new(id, event, Envelope.new(event, id, Time.utc, config.public_url, data).to_json)
      targets.each do |target|
        select
        when target.queue.send(delivery)
        else
          target.dropped.add(1)
        end
      rescue Channel::ClosedError
      end
    end

    def source_connected(mount : String, point : MountPoint) : Nil
      return if point.source_protocol.file?
      details = point.station_details
      emit(SourceConnected.new(mount, point.source_protocol, point.content_type, point.bitrate, details.name, details.genre))
    end

    def source_disconnected(mount : String, point : MountPoint) : Nil
      return if point.source_protocol.file?
      emit(SourceDisconnected.new(mount, point.uptime_seconds, point.listener_stats[1]))
    end

    def song_changed(mount : String, song : String, listeners : Int32, at : Time) : Nil
      emit(SongChanged.new(mount, song, listeners))
    end

    def listener_connected(connection : ListenerConnection) : Nil
      emit(ListenerConnected.new(connection.mount, connection.id, connection.address, connection.user_agent, connection.country))
    end

    def listener_finished(session : ListenerSession) : Nil
      emit(ListenerDisconnected.new(session.mount, session.id, session.address, session.user_agent, session.country,
        session.duration.total_seconds.to_i64, session.bytes_sent))
    end

    def recording_finished(file : Recording::Finished) : Nil
      emit(RecordingFinished.new(file.mount, file.path, File.basename(file.path), file.bytes, file.started_at, file.duration.total_seconds.to_i64))
    end

    def reload_finished(restart_required : Array(String)) : Nil
      emit(ConfigReloaded.new(restart_required))
    end

    private def start_targets(settings : Settings) : Array(Target)
      settings.endpoints.map do |endpoint|
        target = Target.new(endpoint, settings.timeout.seconds)
        spawn deliver_loop(target)
        target
      end
    end

    private def deliver_loop(target : Target)
      client = nil.as(HTTP::Client?)
      while delivery = target.queue.receive?
        if (dropped = target.dropped.swap(0)).positive?
          Log.warn { "Webhook #{target.endpoint.url} fell behind; #{dropped} events were dropped" }
        end
        client = deliver(target, delivery, client)
      end
    ensure
      client.try(&.close)
    end

    # Delivers with retries, reusing *client*'s keep-alive connection. Returns the client to reuse,
    # or nil after a failure so the next delivery connects afresh.
    private def deliver(target : Target, delivery : Delivery, client : HTTP::Client?) : HTTP::Client?
      attempts = RETRY_DELAYS.size + 1
      attempts.times do |attempt|
        client ||= connect(target)
        error = post(client, target.endpoint, delivery)
        return client unless error
        client.close
        client = nil
        if attempt == attempts - 1
          Log.warn { "Webhook #{delivery.event} to #{target.endpoint.url} failed: #{error}" }
        else
          sleep RETRY_DELAYS[attempt]
        end
      end
      nil
    end

    private def connect(target : Target) : HTTP::Client
      client = HTTP::Client.new(URI.parse(target.endpoint.url))
      client.connect_timeout = target.timeout
      client.read_timeout = target.timeout
      client
    end

    # Returns nil on success, or why the delivery failed.
    private def post(client : HTTP::Client, endpoint : Endpoint, delivery : Delivery) : String?
      headers = HTTP::Headers{
        "Content-Type"       => "application/json",
        "User-Agent"         => IcecastServer::SERVER_ID,
        "X-Lurcast-Event"    => delivery.event,
        "X-Lurcast-Delivery" => delivery.id,
      }
      if secret = endpoint.secret
        headers["X-Lurcast-Signature"] = "sha256=#{OpenSSL::HMAC.hexdigest(:sha256, secret, delivery.body)}"
      end
      response = client.post(URI.parse(endpoint.url).request_target, headers, delivery.body)
      response.success? ? nil : "HTTP #{response.status_code}"
    rescue ex
      ex.message || ex.class.name
    end
  end
end
