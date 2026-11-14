require "digest/sha1"
require "http/request"
require "../plugin"

module Lurcast::Plugins
  # Cover art for each mount: the station logo and the cover of the song playing. SHOUTcast 2
  # sources send both inside the stream; for other sources, automation or the dashboard uploads them.
  # Listeners' players fetch them from `/_lurcast/art/<mount>` (listed in the status JSON) or from the
  # SHOUTcast 2 paths `/streamart` and `/playingart`. Station logos are kept in `data_dir`.
  #
  # ```yaml
  # plugins:
  #   cover_art:
  #     enabled: true   # the default
  # ```
  class CoverArt < Plugin
    KEY       = "cover_art"
    PATH      = "/_lurcast/art"
    MAX_BYTES = 1024 * 1024
    TYPES     = {"image/jpeg" => "jpg", "image/png" => "png", "image/gif" => "gif", "image/webp" => "webp", "image/bmp" => "bmp"}

    class Settings
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter? enabled : Bool = true
    end

    record Image, content_type : String, data : Bytes, etag : String do
      def self.new(content_type : String, data : Bytes) : Image
        new(content_type, data, %("#{Digest::SHA1.hexdigest(data)[0, 16]}"))
      end
    end

    def self.build(settings : YAML::Any?, config : Config) : CoverArt?
      parsed = settings ? Plugins.parse(Settings, KEY, settings) : Settings.from_yaml("{}")
      new(config) if parsed.enabled?
    end

    @station = {} of String => Image
    @playing = {} of String => Image
    @mutex = Mutex.new

    def initialize(@config : Config)
    end

    def name : String
      KEY
    end

    def start(server : IcecastServer) : Nil
      load_station_logos
    end

    def artwork_received(mount : String, playing : Bool, content_type : String, data : Bytes) : Nil
      store(mount, playing, data.empty? ? nil : Image.new(content_type, data))
    end

    def artwork_url(mount : String) : String?
      "#{PATH}#{mount}" if image(mount, nil)
    end

    # The image for *mount*: the playing song's cover when *playing* is true, the station logo when
    # false, and either (cover first) when nil.
    def image(mount : String, playing : Bool?) : Image?
      @mutex.synchronize do
        case playing
        when true  then @playing[mount]?
        when false then @station[mount]?
        else            @playing[mount]? || @station[mount]?
        end
      end
    end

    # Sets or (with nil) removes an image.
    def store(mount : String, playing : Bool, image : Image?) : Nil
      @mutex.synchronize do
        images = playing ? @playing : @station
        image ? (images[mount] = image) : images.delete(mount)
      end
      save_station_logo(mount, image) unless playing
    end

    def handle_request(server : IcecastServer, client : IO, request : HTTP::Request, address : String) : Bool
      path = request.path
      case request.method
      when "GET", "HEAD"
        head = request.method == "HEAD"
        if path.starts_with?("#{PATH}/")
          mount = server.mount_name(path.lchop(PATH)) || return false
          playing = case request.query_params["type"]?
                    when "playing" then true
                    when "station" then false
                    end
          send_image(server, client, request, image(mount, playing), head)
        elsif path.in?("/streamart", "/playingart")
          sid = request.query_params["sid"]?.try(&.to_i?) || 1
          mount = @config.shoutcast_mount_for(sid)
          send_image(server, client, request, mount.try { |name| image(name, path == "/playingart") }, head)
        else
          return false
        end
      when "POST"
        case path
        when "/admin/artwork"        then upload(server, client, request)
        when "/admin/artwork/remove" then remove(server, client, request)
        else                              return false
        end
      else
        return false
      end
      true
    end

    private def send_image(server : IcecastServer, client : IO, request : HTTP::Request, image : Image?, head : Bool) : Nil
      unless image
        server.respond_bytes(client, 404, "No artwork".to_slice, "text/plain; charset=utf-8", head: head)
        return
      end
      headers = HTTP::Headers{
        "ETag"                        => image.etag,
        "Cache-Control"               => "no-cache",
        "Access-Control-Allow-Origin" => "*",
        "X-Content-Type-Options"      => "nosniff",
      }
      if request.headers["If-None-Match"]? == image.etag
        server.respond_bytes(client, 304, Bytes.empty, image.content_type, headers, head: true)
      else
        server.respond_bytes(client, 200, image.data, image.content_type, headers, head: head)
      end
    end

    # `POST /admin/artwork?mount=/live&type=playing` with the image as the body (`type=station` for
    # the station logo).
    private def upload(server : IcecastServer, client : IO, request : HTTP::Request) : Nil
      mount, playing = target(server, client, request) || return
      content_type = request.headers["Content-Type"]?.try(&.partition(';')[0].strip.downcase)
      unless content_type && TYPES.has_key?(content_type)
        return error(server, client, 415, "Send a JPEG, PNG, GIF, WebP, or BMP image")
      end
      body = request.body || return error(server, client, 400, "The image is missing")
      data = IO::Memory.new
      if IO.copy(body, data, MAX_BYTES + 1) > MAX_BYTES
        return error(server, client, 413, "Images must be at most #{MAX_BYTES // 1024} KB")
      end
      return error(server, client, 400, "The image is empty") if data.size.zero?
      store(mount, playing, Image.new(content_type, data.to_slice))
      server.respond(client, 200, {artwork: "#{PATH}#{mount}"}.to_json, "application/json")
    end

    private def remove(server : IcecastServer, client : IO, request : HTTP::Request) : Nil
      mount, playing = target(server, client, request) || return
      store(mount, playing, nil)
      server.respond(client, 200, "Artwork removed")
    end

    # The mount and kind an admin request names, after checking the login may manage the mount.
    private def target(server : IcecastServer, client : IO, request : HTTP::Request) : Tuple(String, Bool)?
      access = server.admin_login(request.headers)
      return server.challenge(client, "Lurcast Admin") unless access
      params = request.query_params
      mount = params["mount"]?.try { |value| server.mount_name(value) }
      return error(server, client, 404, "Stream not found") unless mount && access.allows?(mount)
      kind = params["type"]? || "playing"
      return error(server, client, 400, "type must be playing or station") unless kind.in?("playing", "station")
      {mount, kind == "playing"}
    end

    private def error(server : IcecastServer, client : IO, status : Int32, message : String) : Nil
      server.respond(client, status, {error: message}.to_json, "application/json")
    end

    private def logo_directory : String?
      @config.data_dir.try { |dir| File.join(dir, "artwork") }
    end

    # Station logos are files named after the mount, hex-encoded so any mount name is a safe file name.
    private def save_station_logo(mount : String, image : Image?) : Nil
      directory = logo_directory || return
      base = File.join(directory, mount.to_slice.hexstring)
      Dir.mkdir_p(directory)
      TYPES.each_value { |extension| File.delete?("#{base}.#{extension}") }
      return unless image
      temporary = "#{base}.#{Random::Secure.hex(4)}.tmp"
      File.write(temporary, image.data, perm: 0o600)
      File.rename(temporary, "#{base}.#{TYPES[image.content_type]? || "img"}")
    rescue ex : IO::Error
      Log.error { "Could not save the station logo of #{mount}: #{ex.message}" }
    end

    private def load_station_logos : Nil
      directory = logo_directory || return
      return unless Dir.exists?(directory)
      types = TYPES.invert
      Dir.each_child(directory) do |file|
        base, _, extension = file.rpartition('.')
        content_type = types[extension]? || next
        mount = base.hexbytes?.try { |bytes| String.new(bytes) } || next
        data = File.open(File.join(directory, file), &.getb_to_end)
        @mutex.synchronize { @station[mount] = Image.new(content_type, data) }
      end
    rescue ex : IO::Error
      Log.error { "Could not read the station logos: #{ex.message}" }
    end
  end
end
