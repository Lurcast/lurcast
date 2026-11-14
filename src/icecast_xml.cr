require "html"
require "./mount_point"

# Icecast-compatible XML admin responses (`/admin/stats`, `/admin/listmounts`, `/admin/listclients`).
module IcecastXML
  record ServerInfo,
    server_id : String,
    started_at : Time,
    hostname : String,
    admin_email : String,
    public_url : String

  def self.stats(server : ServerInfo, streams : Array(MountPoint), & : MountPoint -> Int32?) : String
    document("icestats") do |io|
      element(io, "admin", server.admin_email)
      element(io, "host", server.hostname)
      element(io, "server_id", server.server_id)
      element(io, "server_start_iso8601", server.started_at.to_rfc3339)
      element(io, "listeners", streams.sum(&.listener_count))
      element(io, "sources", streams.size)
      streams.sort_by(&.mount).each do |stream|
        details = stream.station_details
        listeners, peak, total = stream.listener_stats
        source(io, stream) do
          element(io, "bitrate", stream.bitrate)
          element(io, "genre", details.genre)
          element(io, "listener_connections", total)
          element(io, "listener_peak", peak)
          element(io, "listeners", listeners)
          element(io, "listenurl", "#{server.public_url.rstrip('/')}#{stream.mount}")
          element(io, "max_listeners", yield(stream) || "unlimited")
          element(io, "public", details.listed ? 1 : 0)
          element(io, "server_description", details.description)
          element(io, "server_name", details.name)
          element(io, "server_type", stream.content_type)
          element(io, "server_url", details.url)
          element(io, "stream_start_iso8601", stream.start_time.to_rfc3339)
          element(io, "title", stream.current_song)
          element(io, "total_bytes_sent", stream.bytes_sent)
        end
      end
    end
  end

  def self.list_mounts(streams : Array(MountPoint)) : String
    document("icestats") do |io|
      streams.sort_by(&.mount).each do |stream|
        source(io, stream) do
          element(io, "listeners", stream.listener_count)
          element(io, "Connected", stream.uptime_seconds)
          element(io, "content-type", stream.content_type)
        end
      end
    end
  end

  def self.list_clients(stream : MountPoint) : String
    listeners = stream.listener_details
    document("icestats") do |io|
      source(io, stream) do
        element(io, "Listeners", listeners.size)
        listeners.each do |listener|
          io << "<listener>"
          element(io, "IP", listener.address)
          element(io, "UserAgent", listener.user_agent)
          element(io, "Connected", listener.connected_seconds)
          element(io, "ID", listener.id)
          io << "</listener>"
        end
      end
    end
  end

  def self.response(message : String, success = true) : String
    document("iceresponse") do |io|
      element(io, "message", message)
      element(io, "return", success ? 1 : 0)
    end
  end

  private def self.document(root : String, &) : String
    String.build do |io|
      io << %(<?xml version="1.0" encoding="UTF-8"?>\n<) << root << '>'
      yield io
      io << "</" << root << ">\n"
    end
  end

  private def self.source(io : IO, stream : MountPoint, &)
    io << %(<source mount=") << HTML.escape(stream.mount) << %(">)
    yield
    io << "</source>"
  end

  protected def self.element(io : IO, name : String, value) : Nil
    io << '<' << name << '>' << text(value) << "</" << name << '>'
  end

  # Escapes markup and drops control characters that XML 1.0 cannot represent.
  def self.text(value) : String
    HTML.escape(value.to_s.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, ""))
  end
end
