require "compress/gzip"
require "digest/sha256"

# The stylesheet, scripts, and icon for the built-in pages, compiled into the binary. Their URLs
# carry a content hash, so browsers can cache them for long and still load new versions at once.
module WebAssets
  PREFIX = "/_lurcast"

  FILES = {
    "style.css" => {"text/css; charset=utf-8", {{ read_file("#{__DIR__}/web/style.css") }}},
    "status.js" => {"text/javascript; charset=utf-8", {{ read_file("#{__DIR__}/web/status.js") }}},
    "admin.js"  => {"text/javascript; charset=utf-8", {{ read_file("#{__DIR__}/web/admin.js") }}},
    "icon.svg"  => {"image/svg+xml", {{ read_file("#{__DIR__}/web/icon.svg") }}},
  }

  VERSION = Digest::SHA256.hexdigest(FILES.values.join(&.[1]))[0, 12]

  # Each file compressed once, the first time any is requested.
  GZIPPED = FILES.transform_values do |(_content_type, body)|
    io = IO::Memory.new
    Compress::Gzip::Writer.open(io, level: Compress::Gzip::BEST_COMPRESSION) { |gzip| gzip << body }
    io.to_slice
  end

  def self.url(name : String) : String
    "#{PREFIX}/#{name}?v=#{VERSION}"
  end
end
