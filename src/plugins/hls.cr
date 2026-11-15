require "../plugin"
require "./hls/segmenter"

module Lurcast::Plugins
  # HLS output for MP3 and AAC (ADTS) mounts, without transcoding: a playlist at `/<mount>.m3u8` and
  # segments under `/_lurcast/hls/<mount>/`. Listener logins and the ban list apply to every request.
  #
  # ```yaml
  # plugins:
  #   hls:
  #     segment_seconds: 6
  #     window: 6          # segments in the playlist
  #     mounts: [/live]    # only these mounts; every MP3 and AAC mount when left out
  #     except: [/talk]
  # ```
  class Hls < Plugin
    register "hls"
    dashboard "hls/dashboard.js"

    SEGMENT_PATH = "#{WebAssets::PREFIX}/hls"
    PLAYLIST     = ".m3u8"

    class Settings < Plugin::Settings
      getter segment_seconds : Int32 = 6
      getter window : Int32 = 6
      getter mounts : Array(String)? = nil
      getter except : Array(String) = [] of String

      def validate!(config : Config) : Nil
        invalid("segment_seconds must be between 1 and 30") unless 1 <= segment_seconds <= 30
        invalid("window must be between 3 and 30") unless 3 <= window <= 30
        ((mounts || [] of String) + except).each do |mount|
          invalid("mount names start with /: #{mount}") unless mount.starts_with?('/') && mount.size > 1
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

      def initialize(@point : MountPoint, codec : ::HLS::Codec, @settings : Settings)
        @segmenter = ::HLS::Segmenter.new(codec, settings.segment_seconds.to_f, settings.window)
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

    @[Route("GET", PLAYLIST, suffix: true)]
    private def playlist(context : Context) : Nil
      mount = context.server.mount_name(context.path.rchop(PLAYLIST)) || context.halt(404, "Not found")
      return if context.server.listener_refused?(context.client, mount, context.headers, context.address, head: context.head?)
      tap = tap(mount)
      playlist = tap.try(&.segmenter.playlist("#{SEGMENT_PATH}#{mount}/"))
      context.halt(404, tap ? "Stream is starting; try again in a few seconds" : "HLS is not available for this mount") unless playlist
      context.bytes(playlist.to_slice, "application/vnd.apple.mpegurl", response_headers(context, "no-cache"))
    end

    @[Route("GET", "#{SEGMENT_PATH}/", prefix: true)]
    private def segment(context : Context) : Nil
      mount, _, file = context.path.lchop(SEGMENT_PATH).rpartition('/')
      tap = tap(mount)
      segment = tap.try { |found| file.split('.', 2).first.to_i64?.try { |sequence| found.segmenter.segment(sequence) } }
      context.halt(404, "Segment not found") unless tap && segment
      return if context.server.listener_refused?(context.client, mount, context.headers, context.address, head: context.head?)
      seen(mount, context.server.client_ip(context.headers, context.address))
      max_age = tap.settings.segment_seconds * tap.settings.window
      context.bytes(segment, tap.segmenter.content_type, response_headers(context, "public, max-age=#{max_age}"))
    end

    private def response_headers(context : Context, cache_control : String) : HTTP::Headers
      headers = context.server.cors_headers_for(context.headers) || HTTP::Headers.new
      headers["Cache-Control"] = cache_control
      headers
    end

    private def tap(mount : String) : Tap?
      @mutex.synchronize { @taps[mount]? }
    end

    # Starts or stops HLS for *point* to match the settings, and restarts it when they changed.
    private def sync(point : MountPoint) : Nil
      server = @server || return
      settings = @mutex.synchronize { @settings if @active }
      codec = case point.format
              when "mp3" then ::HLS::Codec::MP3
              when "aac" then point.adts? ? ::HLS::Codec::AAC : nil
              end
      wanted = settings && codec && point.has_source? && !point.source_protocol.file? &&
               settings.serves?(point.mount) &&
               !server.each_listener_checked?(point.mount)
      current = tap(point.mount)
      return if current && wanted && current.point.same?(point) && current.settings.same?(settings)
      remove(point.mount) if current
      return unless wanted && settings && codec
      tap = Tap.new(point, codec, settings)
      added = @mutex.synchronize { @taps.has_key?(point.mount) ? nil : (@taps[point.mount] = tap) }
      point.add_tap(tap) if added
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
