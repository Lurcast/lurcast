require "json"
require "./mount_point"
require "./source_protocol"
require "./extension"

# The admin dashboard's data, served as one `GET /admin/api/overview` response. Fields that do not
# apply (for example the live ones of an offline mount) are nil and left out of the JSON. The
# listener list is large on a busy server, so only the mount named in `?clients=` includes it;
# every live mount has its per-country counts instead.
module AdminAPI
  record Overview, server : Server, access : Access, mounts : Array(Mount) do
    include JSON::Serializable
  end

  record Server,
    id : String,
    hostname : String,
    public_url : String,
    started_at : Time,
    uptime_seconds : Int64,
    listeners : Int32,
    max_listeners : Int32,
    sources : Int32,
    max_sources : Int32,
    port : Int32,
    tls_port : Int32?,
    shoutcast_port : Int32?,
    default_passwords : Array(String),
    features : Features do
    include JSON::Serializable
  end

  # Which optional features are configured, so the dashboard shows only what applies.
  record Features,
    reload : Bool,
    recordings : Bool,
    locations : String?,
    bans_saved : Bool,
    history_saved : Bool,
    plugins : Array(String) do
    include JSON::Serializable
  end

  # Who is signed in: the server admin (`full`), or a login limited to the mounts listed.
  record Access, user : String, full : Bool do
    include JSON::Serializable
  end

  record Recording, started_at : Time, file : String?, manual : Bool do
    include JSON::Serializable
  end

  # A mount: its configuration, and, while a source is connected, its live state.
  record Mount,
    mount : String,
    listen_url : String,
    hidden : Bool,
    fallback : String?,
    max_listeners : Int32?,
    source_username : String,
    relay_url : String?,
    shoutcast_sid : Int32?,
    online : Bool,
    record : Bool,
    recording : Recording? = nil,
    name : String? = nil,
    description : String? = nil,
    genre : String? = nil,
    url : String? = nil,
    listed : Bool? = nil,
    protocol : SourceProtocol? = nil,
    content_type : String? = nil,
    format : String? = nil,
    bitrate : Int32? = nil,
    sample_rate : Int32? = nil,
    channels : Int32? = nil,
    listeners : Int32? = nil,
    peak_listeners : Int32? = nil,
    total_connections : UInt64? = nil,
    unique_listeners : Int32? = nil,
    average_listen_seconds : Int64? = nil,
    started_at : Time? = nil,
    uptime_seconds : Int64? = nil,
    bytes_sent : UInt64? = nil,
    song : String? = nil,
    song_updated_at : Time? = nil,
    history : Array(MountPoint::PlayedSong)? = nil,
    countries : Hash(String, Int32)? = nil,
    clients : Array(MountPoint::ListenerInfo)? = nil do
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    # This mount with the live state of *stream* filled in.
    # *countries* adds listener counts per country code ("" when unknown); *clients* adds the list.
    def with_live(stream : MountPoint, format : String, *, countries : Bool, clients : Bool) : Mount
      details = stream.station_details
      metadata = stream.metadata
      mp3 = stream.mp3_info
      current, peak, total = stream.listener_stats
      copy_with(
        name: details.name, description: details.description, genre: details.genre, url: details.url,
        listed: details.listed, protocol: stream.source_protocol, content_type: stream.content_type, format: format,
        bitrate: mp3.try(&.bitrate_kbps) || stream.bitrate, sample_rate: mp3.try(&.sample_rate_hz), channels: mp3.try(&.channels),
        listeners: current, peak_listeners: peak, total_connections: total, unique_listeners: stream.unique_listener_count,
        average_listen_seconds: stream.average_listen_seconds, started_at: stream.start_time, uptime_seconds: stream.uptime_seconds,
        bytes_sent: stream.bytes_sent, song: metadata.song, song_updated_at: metadata.updated_at,
        history: stream.song_history,
        countries: countries ? stream.listener_countries : nil,
        clients: clients ? stream.listener_details : nil,
      )
    end
  end
end
