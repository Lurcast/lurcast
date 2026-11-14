require "digest/sha1"
require "../plugin"

module Lurcast::Plugins
  # Cover art for each mount: the station logo and the cover of the song playing. SHOUTcast 2
  # sources send both inside the stream; for other sources, automation or the dashboard uploads them.
  # Listeners' players fetch them from `/_lurcast/art/<mount>` (listed in the status JSON) or from the
  # SHOUTcast 2 paths `/streamart` and `/playingart`. Station logos are kept in `data_dir/cover_art/`.
  #
  # ```yaml
  # plugins:
  #   cover_art:
  #     enabled: true   # the default
  # ```
  class CoverArt < Plugin
    register "cover_art", enabled_by_default: true

    PATH      = "/_lurcast/art"
    MAX_BYTES = 1024 * 1024
    TYPES     = {"image/jpeg" => "jpg", "image/png" => "png", "image/gif" => "gif", "image/webp" => "webp", "image/bmp" => "bmp"}

    record Image, content_type : String, data : Bytes, etag : String do
      def self.new(content_type : String, data : Bytes) : Image
        new(content_type, data, %("#{Digest::SHA1.hexdigest(data)[0, 16]}"))
      end
    end

    @station = {} of String => Image
    @playing = {} of String => Image
    @mutex = Mutex.new

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

    # `GET /_lurcast/art/live`: the cover, or the station logo when there is none;
    # `?type=playing` or `?type=station` asks for one of them.
    @[Route("GET", "#{PATH}/", prefix: true)]
    private def art(context : Context) : Nil
      mount = context.server.mount_name(context.path.lchop(PATH)) || context.halt(404, "Stream not found")
      playing = case context.params["type"]?
                when "playing" then true
                when "station" then false
                end
      send_image(context, image(mount, playing))
    end

    # SHOUTcast 2: `/streamart?sid=1` is the station logo and `/playingart?sid=1` the cover.
    @[Route("GET", "/streamart")]
    @[Route("GET", "/playingart")]
    private def shoutcast_art(context : Context) : Nil
      sid = context.params["sid"]?.try(&.to_i?) || 1
      mount = config.shoutcast_mount_for(sid)
      send_image(context, mount.try { |name| image(name, context.path == "/playingart") })
    end

    # `POST /admin/artwork?mount=/live&type=playing` with the image as the body (`type=station` for
    # the station logo).
    @[Route("POST", "/admin/artwork", admin: true)]
    private def upload(context : Context) : Nil
      mount, playing = target(context)
      content_type = context.headers["Content-Type"]?.try(&.partition(';')[0].strip.downcase)
      unless content_type && TYPES.has_key?(content_type)
        context.halt(415, "Send a JPEG, PNG, GIF, WebP, or BMP image")
      end
      body = context.request.body || context.halt(400, "The image is missing")
      data = IO::Memory.new
      context.halt(413, "Images must be at most #{MAX_BYTES // 1024} KB") if IO.copy(body, data, MAX_BYTES + 1) > MAX_BYTES
      context.halt(400, "The image is empty") if data.size.zero?
      store(mount, playing, Image.new(content_type, data.to_slice))
      context.json({artwork: "#{PATH}#{mount}"})
    end

    @[Route("POST", "/admin/artwork/remove", admin: true)]
    private def remove(context : Context) : Nil
      mount, playing = target(context)
      store(mount, playing, nil)
      context.text("Artwork removed")
    end

    private def send_image(context : Context, image : Image?) : Nil
      context.halt(404, "No artwork") unless image
      headers = HTTP::Headers{
        "ETag"                        => image.etag,
        "Cache-Control"               => "no-cache",
        "Access-Control-Allow-Origin" => "*",
        "X-Content-Type-Options"      => "nosniff",
      }
      status = context.headers["If-None-Match"]? == image.etag ? 304 : 200
      context.bytes(status == 304 ? Bytes.empty : image.data, image.content_type, headers, status)
    end

    # The mount and kind (true for the playing cover) an admin request names.
    private def target(context : Context) : Tuple(String, Bool)
      mount = context.mount
      kind = context.params["type"]? || "playing"
      context.halt(400, "type must be playing or station") unless kind.in?("playing", "station")
      {mount, kind == "playing"}
    end

    private def logo_directory : String?
      config.data_dir.try { |dir| File.join(dir, KEY) }
    end

    # Station logos are files named after the mount, hex-encoded so any mount name is a safe file name.
    private def save_station_logo(mount : String, image : Image?) : Nil
      directory = logo_directory || return
      base = File.join(directory, mount.to_slice.hexstring)
      TYPES.each_value { |extension| File.delete?("#{base}.#{extension}") } if Dir.exists?(directory)
      Plugin.write_file("#{base}.#{TYPES[image.content_type]? || "img"}", image.data) if image
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
