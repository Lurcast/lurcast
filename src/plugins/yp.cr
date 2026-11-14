require "../plugin"

module Lurcast::Plugins
  # Lists public mounts in YP directories (the Icecast directory protocol): a mount whose source sends
  # `Ice-Public: 1`, or that is set to listed through the API, is added to every directory, touched
  # with its current song and listener count, and removed when its source leaves or it is unlisted.
  #
  # ```yaml
  # admin_email: ops@example.com   # required: sent to the directories
  # plugins:
  #   yp:
  #     urls: [https://dir.xiph.org/cgi-bin/yp-cgi]
  #     timeout: 15          # seconds (default 15)
  #     touch_interval: 60   # seconds between updates, unless a directory asks for another (default 60)
  # ```
  class Yp < Plugin
    register "yp"

    class Settings < Plugin::Settings
      getter urls : Array(String) = [] of String
      getter timeout : Int32 = 15
      getter touch_interval : Int32 = 60

      def enabled? : Bool
        @enabled && !urls.empty?
      end

      def validate!(config : Config) : Nil
        urls.each { |url| invalid("#{url} must be an http or https URL") unless Plugin.http_url?(url) }
        invalid("admin_email is required for YP publishing") if config.admin_email.empty?
        invalid("timeout must be positive") unless timeout.positive?
        invalid("touch_interval must be positive") unless touch_interval.positive?
      end
    end

    # The running directory loops, by mount object and URL.
    @loops = Set(Tuple(UInt64, String)).new
    @mutex = Mutex.new
    @server : IcecastServer?
    @stopped = Atomic(Bool).new(false)

    def start(server : IcecastServer) : Nil
      @server = server
    end

    def stop : Nil
      @stopped.set(true)
    end

    def reload(settings : Settings?) : Nil
      @mutex.synchronize { @settings = settings || Settings.from_yaml("enabled: false") }
    end

    def source_connected(mount : String, point : MountPoint) : Nil
      list(point) unless point.source_protocol.file?
    end

    def station_updated(mount : String, point : MountPoint) : Nil
      list(point)
    end

    private def list(point : MountPoint) : Nil
      return unless point.listed
      current.urls.each { |url| start_loop(point, url) }
    end

    private def current : Settings
      @mutex.synchronize { settings }
    end

    private def start_loop(point : MountPoint, url : String) : Nil
      key = {point.object_id, url}
      return unless @mutex.synchronize { @loops.add?(key) }
      spawn do
        run(point, url)
      ensure
        @mutex.synchronize { @loops.delete(key) }
        start_loop(point, url) if active?(point, url)
      end
    end

    private def run(point : MountPoint, url : String) : Nil
      while active?(point, url)
        sid = nil.as(String?)
        begin
          response = post(url, add_params(point))
          raise IO::Error.new("YP add rejected") unless success?(response)
          sid = response.headers["SID"]?.presence || raise IO::Error.new("YP add did not return a SID")
          interval = touch_frequency(response, current.touch_interval)
          while active?(point, url)
            pause(interval, point, url)
            break unless active?(point, url)
            response = post(url, touch_params(point, sid))
            raise IO::Error.new("YP touch rejected") unless success?(response)
            interval = touch_frequency(response, interval)
          end
        rescue ex
          Log.warn { "YP directory #{url} failed for #{point.mount}: #{ex.message}" }
        ensure
          if sid
            begin
              post(url, {"action" => "remove", "sid" => sid})
            rescue ex
              Log.warn { "YP remove failed for #{point.mount}: #{ex.message}" }
            end
          end
        end
        pause(current.touch_interval, point, url) if active?(point, url)
      end
    end

    private def post(url : String, params : Hash(String, String)) : HTTP::Client::Response
      Plugin.post_form(url, params, current.timeout.seconds)
    end

    private def add_params(point : MountPoint) : Hash(String, String)
      details = point.station_details
      {
        "action"    => "add",
        "sn"        => details.name,
        "type"      => point.content_type,
        "genre"     => details.genre,
        "b"         => point.bitrate.to_s,
        "listenurl" => "#{config.public_url.rstrip('/')}#{point.mount}",
        "desc"      => details.description,
        "url"       => details.url,
        "email"     => config.admin_email,
      }
    end

    private def touch_params(point : MountPoint, sid : String) : Hash(String, String)
      {
        "action"        => "touch",
        "sid"           => sid,
        "st"            => point.current_song,
        "listeners"     => point.listener_count.to_s,
        "max_listeners" => config.max_listeners.to_s,
      }
    end

    private def success?(response : HTTP::Client::Response) : Bool
      response.status.success? && response.headers["YPResponse"]? == "1"
    end

    private def touch_frequency(response : HTTP::Client::Response, fallback : Int32) : Int32
      interval = response.headers["TouchFreq"]?.try(&.to_i?)
      interval && interval.positive? ? interval : fallback
    end

    # Whether *point* should stay listed in the directory at *url*.
    private def active?(point : MountPoint, url : String) : Bool
      server = @server || return false
      !@stopped.get && current.urls.includes?(url) && server.get_mount(point.mount) == point && point.has_source? && point.listed
    end

    private def pause(seconds : Int32, point : MountPoint, url : String) : Nil
      deadline = Time.instant + seconds.seconds
      while active?(point, url)
        remaining = deadline - Time.instant
        break unless remaining.positive?
        sleep Math.min(remaining, 100.milliseconds)
      end
    end
  end
end
