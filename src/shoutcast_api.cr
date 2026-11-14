require "html"
require "json"
require "./icecast_xml"
require "./mount_point"

# SHOUTcast DNAS 2-compatible statistics (`/7.html`, `/stats`, `/statistics`, `/played`, `admin.cgi?mode=viewxml`).
module ShoutcastAPI
  # A SID-addressed stream. `mount` may have no active source, in which case it reports as offline.
  record Stream, sid : Int32, path : String, mount : MountPoint?, max_listeners : Int32

  # A listener in `admin.cgi?mode=viewjson`.
  record Listener, hostname : String, useragent : String, connecttime : Int64, uid : Int64 do
    include JSON::Serializable
  end

  # A song in `/played` and `admin.cgi?mode=viewjson`.
  record PlayedEntry, playedat : Int64, title : String do
    include JSON::Serializable
  end

  # One stream's statistics, with the DNAS field names in DNAS output order. `id` is only set
  # inside `/statistics`; `listeners` and `songs` only for `admin.cgi?mode=viewjson`.
  record Stats,
    id : Int32?,
    currentlisteners : Int32,
    peaklisteners : Int32,
    maxlisteners : Int32,
    uniquelisteners : Int32,
    averagetime : Int64,
    servergenre : String,
    serverurl : String,
    servertitle : String,
    songtitle : String,
    streamhits : UInt64,
    streamstatus : Int32,
    backupstatus : Int32,
    streamlisted : Int32,
    streampath : String,
    streamuptime : Int64,
    bitrate : String,
    samplerate : String,
    content : String,
    version : String,
    listeners : Array(Listener)? = nil,
    songs : Array(PlayedEntry)? = nil do
    include JSON::Serializable

    alias Value = String | Int32 | Int64 | UInt64

    # The fields as XML elements use them (upper-cased there), without the optional lists.
    def fields : Array(Tuple(String, Value))
      [
        {"currentlisteners", currentlisteners}, {"peaklisteners", peaklisteners},
        {"maxlisteners", maxlisteners}, {"uniquelisteners", uniquelisteners},
        {"averagetime", averagetime}, {"servergenre", servergenre}, {"serverurl", serverurl},
        {"servertitle", servertitle}, {"songtitle", songtitle}, {"streamhits", streamhits},
        {"streamstatus", streamstatus}, {"backupstatus", backupstatus}, {"streamlisted", streamlisted},
        {"streampath", streampath}, {"streamuptime", streamuptime}, {"bitrate", bitrate},
        {"samplerate", samplerate}, {"content", content}, {"version", version},
      ] of Tuple(String, Value)
    end
  end

  # The `/statistics` totals over every stream, followed by the streams.
  record Summary,
    totalstreams : Int32,
    activestreams : Int32,
    currentlisteners : Int32,
    peaklisteners : Int32,
    maxlisteners : Int32,
    uniquelisteners : Int32,
    averagetime : Int64,
    version : String,
    streams : Array(Stats) do
    include JSON::Serializable

    def self.from(all : Array(Tuple(Stream, Stats)), version : String) : Summary
      stats = all.map(&.[1])
      current = stats.sum(&.currentlisteners)
      average = current.zero? ? 0_i64 : stats.sum { |entry| entry.averagetime * entry.currentlisteners } // current
      new(stats.size, stats.count { |entry| entry.streamstatus == 1 }, current, stats.sum(&.peaklisteners),
        stats.sum(&.maxlisteners), stats.sum(&.uniquelisteners), average, version,
        all.map { |stream, entry| entry.copy_with(id: stream.sid) })
    end

    def fields : Array(Tuple(String, String | Int32 | Int64))
      [
        {"totalstreams", totalstreams}, {"activestreams", activestreams}, {"currentlisteners", currentlisteners},
        {"peaklisteners", peaklisteners}, {"maxlisteners", maxlisteners}, {"uniquelisteners", uniquelisteners},
        {"averagetime", averagetime}, {"version", version},
      ] of Tuple(String, String | Int32 | Int64)
    end
  end

  def self.stats(stream : Stream, version : String) : Stats
    mount = stream.mount
    details = mount.try(&.station_details)
    listeners, peak, total = mount.try(&.listener_stats) || {0, 0, 0_u64}
    Stats.new(
      id: nil,
      currentlisteners: listeners,
      peaklisteners: peak,
      maxlisteners: stream.max_listeners,
      uniquelisteners: mount.try(&.unique_listener_count) || 0,
      averagetime: mount.try(&.average_listen_seconds) || 0_i64,
      servergenre: details.try(&.genre) || "",
      serverurl: details.try(&.url) || "",
      servertitle: details.try(&.name) || "",
      songtitle: mount.try(&.current_song) || "",
      streamhits: total,
      streamstatus: mount.try(&.has_source?) ? 1 : 0,
      backupstatus: 0,
      streamlisted: details.try(&.listed) ? 1 : 0,
      streampath: stream.path,
      streamuptime: mount.try(&.uptime_seconds) || 0_i64,
      bitrate: mount.try(&.bitrate.to_s) || "",
      samplerate: mount.try(&.mp3_info).try(&.sample_rate_hz.to_s) || "",
      content: mount.try(&.content_type) || "",
      version: version,
    )
  end

  def self.seven_html(stats : Stats) : String
    values = {stats.currentlisteners, stats.streamstatus, stats.peaklisteners, stats.maxlisteners,
              stats.uniquelisteners, stats.bitrate, stats.songtitle}
    "<html><body>#{HTML.escape(values.join(','))}</body></html>"
  end

  def self.stats_xml(stats : Stats, history : Array(MountPoint::PlayedSong)? = nil, listeners : Array(MountPoint::ListenerInfo)? = nil) : String
    document do |io|
      stats_elements(io, stats)
      listeners_elements(io, listeners) if listeners
      history_elements(io, history) if history
    end
  end

  def self.stats_json(stats : Stats, history : Array(MountPoint::PlayedSong)? = nil, listeners : Array(MountPoint::ListenerInfo)? = nil) : String
    stats.copy_with(
      listeners: listeners.try(&.map { |listener| Listener.new(listener.address, listener.user_agent, listener.connected_seconds, listener.id) }),
      songs: history.try { |songs| played_entries(songs) },
    ).to_json
  end

  def self.statistics_xml(streams : Array(Stream), version : String) : String
    summary = Summary.from(streams.map { |stream| {stream, stats(stream, version)} }, version)
    document do |io|
      io << "<STREAMSTATS>"
      summary.fields.each { |name, value| element(io, name.upcase, value) }
      summary.streams.each do |stream|
        io << %(<STREAM id=") << stream.id << %(">)
        stats_elements(io, stream)
        io << "</STREAM>"
      end
      io << "</STREAMSTATS>"
    end
  end

  def self.statistics_json(streams : Array(Stream), version : String) : String
    Summary.from(streams.map { |stream| {stream, stats(stream, version)} }, version).to_json
  end

  def self.played_json(history : Array(MountPoint::PlayedSong)) : String
    played_entries(history).to_json
  end

  def self.played_xml(history : Array(MountPoint::PlayedSong)) : String
    document { |io| history_elements(io, history) }
  end

  private def self.stats_elements(io : IO, stats : Stats)
    stats.fields.each { |name, value| element(io, name.upcase, value) }
  end

  private def self.listeners_elements(io : IO, listeners : Array(MountPoint::ListenerInfo))
    io << "<LISTENERS>"
    listeners.each do |listener|
      io << "<LISTENER>"
      element(io, "HOSTNAME", listener.address)
      element(io, "USERAGENT", listener.user_agent)
      element(io, "CONNECTTIME", listener.connected_seconds)
      element(io, "UID", listener.id)
      io << "</LISTENER>"
    end
    io << "</LISTENERS>"
  end

  private def self.history_elements(io : IO, history : Array(MountPoint::PlayedSong))
    io << "<SONGHISTORY>"
    history.each do |song|
      io << "<SONG>"
      element(io, "PLAYEDAT", song.played_at.to_unix)
      element(io, "TITLE", song.title)
      io << "</SONG>"
    end
    io << "</SONGHISTORY>"
  end

  private def self.played_entries(history : Array(MountPoint::PlayedSong)) : Array(PlayedEntry)
    history.map { |song| PlayedEntry.new(song.played_at.to_unix, song.title) }
  end

  private def self.document(&) : String
    String.build do |io|
      io << %(<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>\n<SHOUTCASTSERVER>)
      yield io
      io << "</SHOUTCASTSERVER>\n"
    end
  end

  private def self.element(io : IO, name : String, value) : Nil
    io << '<' << name << '>' << IcecastXML.text(value) << "</" << name << '>'
  end
end
