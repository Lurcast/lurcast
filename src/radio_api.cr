require "json"
require "./mount_point"
require "./extension"

module RadioAPI
  MAX_UPDATE_BYTES = 65_536

  struct Update
    include JSON::Serializable
    include JSON::Serializable::Strict

    getter name : String?
    getter description : String?
    getter genre : String?
    getter url : String?
    getter listed : Bool?
    getter current_song : String?

    def validate!
      values = {@name, @description, @genre, @url, @current_song}
      raise ArgumentError.new("station fields must not exceed 4096 bytes") if values.any? { |value| !value.nil? && value.bytesize > 4096 }
      raise ArgumentError.new("at least one station field is required") if values.all?(Nil) && @listed.nil?
    end
  end

  record Response, api_version : String, server : ServerInfo, stations : Array(Station) do
    include JSON::Serializable
  end

  record Error, error : String do
    include JSON::Serializable
  end

  record ServerInfo,
    id : String,
    started_at : Time,
    uptime_seconds : Int64,
    listeners : Int32,
    sources : Int32 do
    include JSON::Serializable
  end

  record Station,
    mount : String,
    listen_url : String,
    online : Bool,
    source_protocol : SourceProtocol,
    station : StationInfo,
    now_playing : NowPlaying,
    stream : StreamInfo,
    listeners : ListenerInfo,
    started_at : Time,
    uptime_seconds : Int64,
    bytes_sent : UInt64 do
    include JSON::Serializable
    include JSON::Serializable::Unmapped
  end

  record StationInfo,
    name : String,
    description : String,
    genre : String,
    url : String,
    listed : Bool do
    include JSON::Serializable
  end

  record NowPlaying, song : String?, updated_at : Time? do
    include JSON::Serializable
    include JSON::Serializable::Unmapped
  end

  record StreamInfo,
    content_type : String,
    bitrate_kbps : Int32,
    sample_rate_hz : Int32?,
    channels : Int32?,
    mpeg_version : String?,
    mpeg_layer : Int32? do
    include JSON::Serializable
  end

  record ListenerInfo, current : Int32, peak : Int32, total : UInt64 do
    include JSON::Serializable
  end

  # Fields gives the extra fields for a mount in a view (see `Lurcast::Extension#mount_fields`).
  alias Fields = Proc(String, Lurcast::MountView, Hash(String, JSON::Any))

  def self.render(server_id : String, public_url : String, started_at : Time, streams : Array(MountPoint), fields : Fields? = nil) : String
    base_url = public_url.rstrip('/')
    stations = streams.map { |stream| station(base_url, stream, fields) }.sort_by!(&.mount)
    server = ServerInfo.new(
      server_id,
      started_at,
      (Time.utc - started_at).total_seconds.to_i64,
      streams.sum(&.listener_count),
      streams.count(&.has_source?)
    )
    Response.new("1", server, stations).to_json
  end

  def self.render_station(public_url : String, stream : MountPoint, fields : Fields? = nil) : String
    station(public_url.rstrip('/'), stream, fields).to_json
  end

  private def self.station(base_url : String, stream : MountPoint, fields : Fields?) : Station
    details = stream.station_details
    metadata = stream.metadata
    mp3 = stream.mp3_info
    current_listeners, peak_listeners, total_connections = stream.listener_stats
    now_playing = NowPlaying.new(metadata.song.empty? ? nil : metadata.song, metadata.updated_at)
    station = Station.new(
      stream.mount,
      "#{base_url}#{stream.mount}",
      stream.has_source?,
      stream.source_protocol,
      StationInfo.new(details.name, details.description, details.genre, details.url, details.listed),
      now_playing,
      StreamInfo.new(
        stream.content_type,
        mp3.try(&.bitrate_kbps) || stream.bitrate,
        mp3.try(&.sample_rate_hz),
        mp3.try(&.channels),
        mp3.try(&.version),
        mp3.try(&.layer)
      ),
      ListenerInfo.new(current_listeners, peak_listeners, total_connections),
      stream.start_time,
      stream.uptime_seconds,
      stream.bytes_sent
    )
    if extra = fields
      station.json_unmapped.merge!(extra.call(stream.mount, Lurcast::MountView::Station))
      now_playing.json_unmapped.merge!(extra.call(stream.mount, Lurcast::MountView::NowPlaying))
    end
    station
  end
end
