require "json"
require "./mount_point"

module IcecastAPI
  record Response, icestats : Stats do
    include JSON::Serializable
  end

  record Stats,
    server_id : String,
    server_start_iso8601 : Time,
    listeners : Int32,
    sources : Int32,
    source : Array(Source) do
    include JSON::Serializable
  end

  record Source,
    mount : String,
    name : String,
    genre : String,
    url : String,
    bitrate : Int32,
    content_type : String,
    listeners : Int32,
    listener_peak : Int32,
    total_connections : UInt64,
    has_source : Bool,
    title : String,
    stream_start_iso8601 : Time,
    uptime_seconds : Int64,
    total_bytes_sent : UInt64 do
    include JSON::Serializable
  end

  def self.render(server_id : String, started_at : Time, streams : Array(MountPoint)) : String
    sources = streams.map { |stream| source(stream) }
    stats = Stats.new(server_id, started_at, sources.sum(&.listeners), sources.size, sources)
    Response.new(stats).to_json
  end

  private def self.source(stream : MountPoint) : Source
    details = stream.station_details
    listeners, peak, total = stream.listener_stats
    Source.new(
      stream.mount,
      details.name,
      details.genre,
      details.url,
      stream.bitrate,
      stream.content_type,
      listeners,
      peak,
      total,
      stream.has_source?,
      stream.current_song,
      stream.start_time,
      stream.uptime_seconds,
      stream.bytes_sent
    )
  end
end
