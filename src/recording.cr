require "log"
require "./mount_point"

# Records one mount's audio to files under `<recordings_dir>/<mount>/`, named by the UTC time each
# file starts (for example `live/2026-11-13_22-01-14.mp3`). It receives the same frame-aligned data
# listeners get, so MP3 and AAC files can be split at any chunk and still play. Ogg files are never
# split, because each part would need the stream headers again.
class Recording < AudioTap
  Log = ::Log.for("lurcast.recording")

  QUEUE_SIZE = 2048

  record Finished,
    mount : String,
    path : String,
    bytes : Int64,
    started_at : Time,
    duration : Time::Span

  getter mount : String
  getter started_at : Time = Time.utc
  getter? manual : Bool
  @queue = Channel(Bytes).new(QUEUE_SIZE)
  @dropped = Atomic(Int64).new(0_i64)
  @current_path = Atomic(String?).new(nil)
  @done = Channel(Nil).new

  def initialize(@mount : String, @directory : String, @extension : String, @split : Time::Span?, @manual = false, &@on_file : Finished ->)
    spawn write_loop
  end

  def self.extension_for(content_type : String) : String
    case content_type.split(';').first.strip.downcase
    when "audio/mpeg", "audio/mp3"                     then "mp3"
    when "audio/aac", "audio/aacp", "audio/x-aac"      then "aac"
    when "audio/ogg", "application/ogg", "audio/x-ogg" then "ogg"
    when "audio/opus"                                  then "opus"
    when "audio/flac", "audio/x-flac"                  then "flac"
    when "audio/webm", "video/webm"                    then "webm"
    else                                                    "bin"
    end
  end

  # The directory name for *mount*: its path with `/` replaced by `_` and anything unusual dropped.
  def self.slug(mount : String) : String
    slug = mount.lchop('/').gsub('/', '_').gsub(/[^A-Za-z0-9._-]/, "")
    slug.empty? || slug.matches?(/\A\.+\z/) ? "_" : slug
  end

  def current_path : String?
    @current_path.get
  end

  def receive(data : Bytes) : Nil
    select
    when @queue.send(data.dup)
    else
      @dropped.add(1)
    end
  rescue Channel::ClosedError
  end

  # Finishes the current file. Returns once everything received so far is written.
  def stop : Nil
    @queue.close
    @done.receive?
  end

  private def write_loop
    file = nil.as(File?)
    file_started = Time.instant
    file_started_at = Time.utc
    bytes = 0_i64
    flushed = Time.instant
    begin
      while data = @queue.receive?
        if file && (split = @split) && Time.instant - file_started >= split
          finish(file, file_started_at, file_started, bytes)
          file = nil
        end
        unless file
          file = open_file
          file_started = Time.instant
          file_started_at = Time.utc
          bytes = 0_i64
        end
        file.write(data)
        bytes += data.size
        if Time.instant - flushed >= 1.second
          file.flush
          flushed = Time.instant
        end
        if (dropped = @dropped.swap(0)).positive?
          Log.warn { "Recording #{@mount} fell behind the disk; #{dropped} chunks were lost" }
        end
      end
    rescue ex
      Log.error(exception: ex) { "Recording #{@mount} failed" }
    end
    finish(file, file_started_at, file_started, bytes) if file
    @current_path.set(nil)
    @done.close
  end

  private def open_file : File
    directory = File.join(@directory, self.class.slug(@mount))
    Dir.mkdir_p(directory)
    base = Time.utc.to_s("%Y-%m-%d_%H-%M-%S")
    path = File.join(directory, "#{base}.#{@extension}")
    suffix = 1
    while File.exists?(path)
      path = File.join(directory, "#{base}-#{suffix}.#{@extension}")
      suffix += 1
    end
    @current_path.set(path)
    Log.info { "Recording #{@mount} to #{path}" }
    file = File.open(path, "wb")
    file.buffer_size = 64 * 1024 # fewer, larger disk writes; flushed at least once a second
    file
  end

  private def finish(file : File, started_at : Time, started : Time::Instant, bytes : Int64)
    file.close
    @on_file.call(Finished.new(@mount, file.path, bytes, started_at, Time.instant - started))
  rescue ex
    Log.error(exception: ex) { "Recording #{@mount} could not finish #{file.path}" }
  end
end
