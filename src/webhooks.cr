require "http/client"
require "json"
require "log"
require "openssl/hmac"
require "uuid"
require "./source_protocol"
require "./config"

# Sends server events as JSON POST requests to the configured webhook URLs:
#
#   {"event": "song.changed", "id": "2f1c…", "at": "2026-11-13T22:01:14Z", "server": "https://radio.example",
#    "data": {"mount": "/live", "song": "Artist - Title", "listeners": 42}}
#
# Each request carries `X-Lurcast-Event`, `X-Lurcast-Delivery` (the id), and, with a secret,
# `X-Lurcast-Signature: sha256=<hex HMAC-SHA256 of the body>`. A response other than 2xx is
# retried twice, after 2 and 10 seconds. Each webhook has its own bounded queue, so a slow
# receiver never delays streaming; events that do not fit are dropped and logged.
class Webhooks
  Log = ::Log.for("lurcast.webhooks")

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

  QUEUE_SIZE   = 1024
  RETRY_DELAYS = [2.seconds, 10.seconds]

  private record Delivery, id : String, event : String, body : String

  private class Target
    getter config : WebhookConfig
    getter queue = Channel(Delivery).new(QUEUE_SIZE)
    getter dropped = Atomic(Int64).new(0_i64)

    def initialize(@config : WebhookConfig)
    end
  end

  @targets : Array(Target)

  def initialize(configs : Array(WebhookConfig), @server_url : String, @server_id : String, @timeout : Time::Span)
    @targets = configs.map { |config| Target.new(config) }
    @targets.each { |target| spawn deliver_loop(target) }
  end

  # Queues *data*, one of the event records above, for every webhook subscribed to its event.
  def emit(data : T) : Nil forall T
    return if @targets.empty?
    event = T::EVENT
    targets = @targets.select(&.config.wants?(event))
    return if targets.empty?

    id = UUID.random.to_s
    delivery = Delivery.new(id, event, Envelope.new(event, id, Time.utc, @server_url, data).to_json)
    targets.each do |target|
      select
      when target.queue.send(delivery)
      else
        target.dropped.add(1)
      end
    rescue Channel::ClosedError
    end
  end

  def close : Nil
    @targets.each(&.queue.close)
  end

  private def deliver_loop(target : Target)
    client = nil.as(HTTP::Client?)
    while delivery = target.queue.receive?
      if (dropped = target.dropped.swap(0)).positive?
        Log.warn { "Webhook #{target.config.url} fell behind; #{dropped} events were dropped" }
      end
      client = deliver(target.config, delivery, client)
    end
  ensure
    client.try(&.close)
  end

  # Delivers with retries, reusing *client*'s keep-alive connection. Returns the client to reuse,
  # or nil after a failure so the next delivery connects afresh.
  private def deliver(config : WebhookConfig, delivery : Delivery, client : HTTP::Client?) : HTTP::Client?
    attempts = RETRY_DELAYS.size + 1
    attempts.times do |attempt|
      client ||= connect(config)
      error = post(client, config, delivery)
      return client unless error
      client.close
      client = nil
      if attempt == attempts - 1
        Log.warn { "Webhook #{delivery.event} to #{config.url} failed: #{error}" }
      else
        sleep RETRY_DELAYS[attempt]
      end
    end
    nil
  end

  private def connect(config : WebhookConfig) : HTTP::Client
    client = HTTP::Client.new(URI.parse(config.url))
    client.connect_timeout = @timeout
    client.read_timeout = @timeout
    client
  end

  # Returns nil on success, or why the delivery failed.
  private def post(client : HTTP::Client, config : WebhookConfig, delivery : Delivery) : String?
    headers = HTTP::Headers{
      "Content-Type"       => "application/json",
      "User-Agent"         => @server_id,
      "X-Lurcast-Event"    => delivery.event,
      "X-Lurcast-Delivery" => delivery.id,
    }
    if secret = config.secret
      headers["X-Lurcast-Signature"] = "sha256=#{OpenSSL::HMAC.hexdigest(:sha256, secret, delivery.body)}"
    end
    response = client.post(URI.parse(config.url).request_target, headers, delivery.body)
    response.success? ? nil : "HTTP #{response.status_code}"
  rescue ex
    ex.message || ex.class.name
  end
end
