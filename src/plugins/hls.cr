require "../plugin"
require "./hls/segmenter"

module Lurcast::Plugins
  # HLS output without transcoding: a playlist at `/<mount>.m3u8` and segments under
  # `/_lurcast/hls/<mount>/`. MP3 and AAC mounts get packed audio; AAC in LATM is rewritten as ADTS.
  # Opus and FLAC (in Ogg, or native FLAC) get fragmented MP4. Listener logins and the ban list
  # apply to every request.
  #
  # ```yaml
  # plugins:
  #   hls:
  #     segment_seconds: 6
  #     window: 6            # segments in the playlist
  #     mounts: [/live]      # only these mounts; every mount it can serve when left out
  #     except: [/talk]
  #     low_latency: false   # partial segments and blocking playlist reloads (AAC, Opus and FLAC)
  #     part_seconds: 1.0
  #     variants:            # multivariant playlists: /radio.m3u8 offers both mounts
  #       /radio: [/live, /live-mobile]
  # ```
  class Hls < Plugin
    register "hls"
    dashboard "hls/dashboard.js"

    SEGMENT_PATH = "#{WebAssets::PREFIX}/hls"
    PLAYLIST     = ".m3u8"
    SEGMENT_FILE = /\A(\d+)(?:\.(\d+))?\.(mp3|aac|m4s)\z/
    INIT_FILE    = /\Ainit-(\d+)\.mp4\z/

    class Settings < Plugin::Settings
      getter segment_seconds : Int32 = 6
      getter window : Int32 = 6
      getter mounts : Array(String)? = nil
      getter except : Array(String) = [] of String
      getter? low_latency : Bool = false
      getter part_seconds : Float64 = 1.0
      getter variants : Hash(String, Array(String)) = {} of String => Array(String)

      def validate!(config : Config) : Nil
        invalid("segment_seconds must be between 1 and 30") unless 1 <= segment_seconds <= 30
        invalid("window must be between 3 and 30") unless 3 <= window <= 30
        if low_latency?
          invalid("part_seconds must be between 0.2 and 2, and less than segment_seconds") unless 0.2 <= part_seconds <= 2.0 && part_seconds < segment_seconds
        end
        ((mounts || [] of String) + except + variants.keys + variants.values.flatten).each do |mount|
          invalid("mount names start with /: #{mount}") unless mount.starts_with?('/') && mount.size > 1
        end
        variants.each do |name, list|
          invalid("variants #{name} lists no mounts") if list.empty?
          invalid("variants #{name} lists itself") if list.includes?(name)
        end
      end

      def serves?(mount : String) : Bool
        mounts.try(&.includes?(mount)) != false && !except.includes?(mount)
      end
    end

    # Feeds a mount's audio to its segmenter, with the song playing at that moment.
    private class Tap < AudioTap
      getter segmenter : ::HLS::Segmenter
      getter point : MountPoint
      getter settings : Settings

      def initialize(@point : MountPoint, @segmenter : ::HLS::Segmenter, @settings : Settings)
      end

      def receive(data : Bytes) : Nil
        @segmenter.write(data, @point.current_song)
      end
    end

    @server : IcecastServer?
    @active = true
    @taps = {} of String => Tap
    @clients = {} of String => Hash(String, Time::Instant)
    @pruned_at = Time.instant
    @mutex = Mutex.new

    def start(server : IcecastServer) : Nil
      @server = server
      server.streams.each { |point| sync(point) }
    end

    def stop : Nil
      @mutex.synchronize { @active = false }
      @server.try { |server| server.streams.each { |point| remove(point.mount) } }
    end

    def reload(settings : Settings?) : Nil
      @mutex.synchronize do
        @settings = settings if settings
        @active = !settings.nil?
      end
      @server.try { |server| server.streams.each { |point| sync(point) } }
    end

    def source_connected(mount : String, point : MountPoint) : Nil
      sync(point)
    end

    def source_disconnected(mount : String, point : MountPoint) : Nil
      remove(mount)
    end

    # The dashboard shows the playlist and the HLS listeners as `hls_url` and `hls_listeners`.
    def mount_fields(mount : String, view : MountView) : Hash(String, JSON::Any)?
      return unless view.admin? && tap(mount)
      {
        "hls_url"       => JSON::Any.new("#{config.public_url.rstrip('/')}#{mount}#{PLAYLIST}"),
        "hls_listeners" => JSON::Any.new(listener_count(mount).to_i64),
      }
    end

    # Listeners using HLS, counted as addresses that fetched a segment in the last few segment lengths.
    def listener_count(mount : String) : Int32
      now = Time.instant
      @mutex.synchronize do
        clients = @clients[mount]?
        next 0 unless clients
        clients.reject! { |_address, seen| now - seen > client_window }
        clients.size
      end
    end

    @[Route("GET", PLAYLIST, suffix: true, listener: true)]
    private def playlist(context : Context) : Nil
      name = context.path.rchop(PLAYLIST)
      variants = @mutex.synchronize { settings.variants[name]? }
      return multivariant(context, variants) if variants
      mount = context.server.mount_name(name) || context.halt(404, "Not found")
      return if context.server.listener_refused?(context.client, mount, context.headers, context.address, head: context.head?)
      tap = tap(mount) || context.halt(404, "HLS is not available for this mount")
      segmenter = tap.segmenter
      if reason = segmenter.unsupported
        context.halt(404, "HLS is not available for this mount: #{reason}")
      end
      block_until_requested(context, segmenter)
      playlist = segmenter.playlist("#{SEGMENT_PATH}#{mount}/") || context.halt(404, "Stream is starting; try again in a few seconds")
      context.bytes(playlist.to_slice, "application/vnd.apple.mpegurl", response_headers(context, "no-cache"))
    end

    @[Route("GET", "#{SEGMENT_PATH}/", prefix: true, listener: true)]
    private def segment(context : Context) : Nil
      mount, _, file = context.path.lchop(SEGMENT_PATH).rpartition('/')
      tap = tap(mount) || context.halt(404, "Segment not found")
      segmenter = tap.segmenter
      if match = INIT_FILE.match(file)
        init = segmenter.init(match[1].to_i) || context.halt(404, "Segment not found")
        return if context.server.listener_refused?(context.client, mount, context.headers, context.address, head: context.head?)
        return context.bytes(init, "audio/mp4", response_headers(context, "public, max-age=3600"))
      end
      match = SEGMENT_FILE.match(file) || context.halt(404, "Segment not found")
      context.halt(404, "Segment not found") unless match[3] == segmenter.extension
      sequence = match[1].to_i64
      data = if part = match[2]?.try(&.to_i)
               # A preload hint names the next part before it exists: wait for it.
               if sequence <= segmenter.next_sequence + 1
                 segmenter.wait_for(sequence, part, (tap.settings.part_seconds * 3).seconds)
               end
               segmenter.part(sequence, part)
             else
               segmenter.segment(sequence)
             end
      context.halt(404, "Segment not found") unless data
      return if context.server.listener_refused?(context.client, mount, context.headers, context.address, head: context.head?)
      seen(mount, context.server.client_ip(context.headers, context.address))
      max_age = tap.settings.segment_seconds * tap.settings.window
      context.bytes(data, segmenter.content_type, response_headers(context, "public, max-age=#{max_age}"))
    end

    # A blocking playlist reload (`_HLS_msn`, `_HLS_part`): waits until the playlist has that segment
    # or part, at most three target durations.
    private def block_until_requested(context : Context, segmenter : ::HLS::Segmenter) : Nil
      return unless segmenter.low_latency?
      msn = context.params["_HLS_msn"]?.try(&.to_i64?) || return
      part = context.params["_HLS_part"]?.try(&.to_i?)
      context.halt(400, "_HLS_msn is too far ahead") if msn > segmenter.next_sequence + 2
      segmenter.wait_for(msn, part, (settings.segment_seconds * 3).seconds)
    end

    # A multivariant playlist offering each listed mount that is on the air with HLS.
    private def multivariant(context : Context, mounts : Array(String)) : Nil
      variants = mounts.compact_map do |mount|
        segmenter = tap(mount).try(&.segmenter) || next
        codecs = segmenter.codecs || next
        point = context.server.get_mount(mount)
        peak = segmenter.peak_bandwidth || (point.try(&.bitrate) || 128) * 1100
        {mount, peak, segmenter.average_bandwidth, codecs}
      end
      context.halt(404, "None of these streams is on the air") if variants.empty?
      playlist = String.build do |io|
        io << "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        variants.each do |(mount, peak, average, codecs)|
          io << "#EXT-X-STREAM-INF:BANDWIDTH=" << peak
          io << ",AVERAGE-BANDWIDTH=" << average if average
          io << ",CODECS=\"" << codecs << "\"\n"
          io << mount << PLAYLIST << '\n'
        end
      end
      context.bytes(playlist.to_slice, "application/vnd.apple.mpegurl", response_headers(context, "no-cache"))
    end

    private def response_headers(context : Context, cache_control : String) : HTTP::Headers
      headers = context.server.cors_headers_for(context.headers) || HTTP::Headers.new
      headers["Cache-Control"] = cache_control
      headers
    end

    private def tap(mount : String) : Tap?
      @mutex.synchronize { @taps[mount]? }
    end

    # The segmenter for *point*'s format, or nil when HLS can't serve it.
    private def segmenter_for(point : MountPoint, settings : Settings) : ::HLS::Segmenter?
      framer, fmp4 = case point.format
                     when "mp3"  then {::HLS::MP3Framer.new, false}
                     when "aac"  then {::HLS::AACFramer.new, settings.low_latency?}
                     when "ogg"  then {::HLS::OggFramer.new, true}
                     when "flac" then {::HLS::FLACFramer.new, true}
                     else             return
                     end
      container = fmp4 ? ::HLS::Container::FMP4 : ::HLS::Container::Packed
      part = settings.part_seconds if fmp4 && settings.low_latency?
      ::HLS::Segmenter.new(framer, container, settings.segment_seconds.to_f, settings.window, part_seconds: part)
    end

    # Starts or stops HLS for *point* to match the settings, and restarts it when they changed.
    private def sync(point : MountPoint) : Nil
      server = @server || return
      settings = @mutex.synchronize { @settings if @active }
      wanted = settings && point.has_source? && !point.source_protocol.file? &&
               settings.serves?(point.mount) &&
               !server.each_listener_checked?(point.mount)
      current = tap(point.mount)
      return if current && wanted && current.point.same?(point) && current.settings.same?(settings)
      remove(point.mount) if current
      return unless wanted && settings
      segmenter = segmenter_for(point, settings) || return
      tap = Tap.new(point, segmenter, settings)
      added = @mutex.synchronize { @taps.has_key?(point.mount) ? nil : (@taps[point.mount] = tap) }
      # With the buffered audio first, so Ogg and FLAC streams start with their headers.
      point.add_tap(tap, burst: true) if added
    end

    private def remove(mount : String) : Nil
      tap = @mutex.synchronize do
        @clients.delete(mount)
        @taps.delete(mount)
      end
      tap.try { |removed| removed.point.remove_tap(removed) }
    end

    # Remembers that *address* fetched a segment. Old entries are dropped every so often, so the table
    # stays small even when nobody opens the dashboard.
    private def seen(mount : String, address : String) : Nil
      now = Time.instant
      @mutex.synchronize do
        (@clients[mount] ||= {} of String => Time::Instant)[address] = now
        window = client_window
        if now - @pruned_at > window
          @pruned_at = now
          @clients.each_value(&.reject! { |_address, last| now - last > window })
        end
      end
    end

    private def client_window : Time::Span
      (settings.segment_seconds * 3).seconds
    end
  end
end
