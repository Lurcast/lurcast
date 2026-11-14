require "json"
require "log"

# Listener counts over time, for the dashboard's charts. The server takes a sample of every mount
# once a minute, and keeps the samples at three resolutions: 5 minutes for 2 days, 1 hour for 35
# days, and 1 day for 2 years.
#
# The server total (`TOTAL`) gets a bucket for every period the server was running, with the number
# of samples taken. A mount only gets buckets in which it had listeners, so an idle mount costs
# nothing; a mount without a bucket where the total has one had no listeners then, and a period
# without a total bucket is shown as a gap, because the server was not running.
class ListenerHistory
  Log = ::Log.for("lurcast.history")

  TOTAL = ""
  MAGIC = "LCH1"

  # A bucket length in seconds, and how many buckets to keep.
  record Resolution, step : Int32, keep : Int32

  RESOLUTIONS = {Resolution.new(300, 576), Resolution.new(3600, 840), Resolution.new(86_400, 732)}

  # The chart ranges: which resolution each uses, and how many buckets it shows.
  RANGES = {"day" => {0, 288}, "week" => {1, 168}, "month" => {1, 720}, "year" => {2, 365}}

  # The sum and peak of the samples in one bucket; *samples* is only counted for the total.
  record Bucket, index : Int64, sum : Int64, samples : Int32, peak : Int32 do
    def add(count : Int32) : Bucket
      Bucket.new(index, sum + count, samples + 1, Math.max(peak, count))
    end
  end

  # One point on a chart: the bucket's start time (Unix seconds), the average and the peak number of
  # listeners, or nils when the server was not running.
  alias Point = Tuple(Int64, Float64?, Int32?)

  @[JSON::Serializable::Options(emit_nulls: true)]
  record Chart, mount : String?, range : String, step_seconds : Int32, points : Array(Point) do
    include JSON::Serializable
  end

  @series = {} of String => Array(Deque(Bucket))
  @mutex = Mutex.new

  def initialize(@path : String? = nil)
    load
  end

  # Adds one sample: the listener count of each mount at *now*. The total is their sum.
  def record(counts : Hash(String, Int32), now = Time.utc) : Nil
    seconds = now.to_unix
    @mutex.synchronize do
      add(TOTAL, counts.each_value.sum, seconds)
      counts.each do |mount, count|
        add(mount, count, seconds) if count.positive? && mount != TOTAL
      end
      prune(seconds)
    end
  end

  # The chart for *mount* (or the server total for `TOTAL`) over *range*, one of `RANGES`.
  def chart(mount : String, range : String, now = Time.utc) : Chart
    level, count = RANGES[range]? || raise ArgumentError.new("range must be one of #{RANGES.keys.join(", ")}")
    step = RESOLUTIONS[level].step
    last = now.to_unix // step
    first = last - count + 1
    points = @mutex.synchronize do
      totals = window(TOTAL, level, first)
      values = mount == TOTAL ? totals : window(mount, level, first)
      (first..last).map do |index|
        total = totals[index]?
        next {index * step, nil, nil}.as(Point) unless total
        bucket = values[index]?
        average = bucket ? (bucket.sum / total.samples).round(1) : 0.0
        {index * step, average, bucket.try(&.peak) || 0}.as(Point)
      end
    end
    Chart.new(mount == TOTAL ? nil : mount, range, step, points)
  end

  # Drops the history of *mount*, for example when a station is deleted.
  def forget(mount : String) : Nil
    @mutex.synchronize { @series.delete(mount) }
  end

  # Writes the history to the file it was loaded from, replacing it atomically.
  def save : Nil
    return unless path = @path
    Dir.mkdir_p(File.dirname(path))
    temporary = "#{path}.#{Random::Secure.hex(4)}.tmp"
    File.open(temporary, "w", perm: 0o600) do |file|
      file.buffer_size = 64 * 1024
      @mutex.synchronize { write(file) }
    end
    File.rename(temporary, path)
  rescue ex : IO::Error
    Log.error { "Could not save the listener history to #{path}: #{ex.message}" }
  end

  private def add(mount : String, count : Int32, seconds : Int64) : Nil
    series = @series[mount] ||= Array.new(RESOLUTIONS.size) { Deque(Bucket).new }
    RESOLUTIONS.each_with_index do |resolution, level|
      buckets = series[level]
      index = seconds // resolution.step
      last = buckets.last?
      if last && last.index == index
        buckets[-1] = last.add(count)
      elsif last.nil? || last.index < index
        buckets << Bucket.new(index, count.to_i64, 1, count)
      end
    end
  end

  private def prune(seconds : Int64) : Nil
    @series.reject! do |_mount, series|
      RESOLUTIONS.each_with_index do |resolution, level|
        oldest = seconds // resolution.step - resolution.keep
        buckets = series[level]
        while (first = buckets.first?) && first.index <= oldest
          buckets.shift
        end
      end
      series.all?(&.empty?)
    end
  end

  private def window(mount : String, level : Int32, first : Int64) : Hash(Int64, Bucket)
    buckets = @series[mount]?.try(&.[level]) || return {} of Int64 => Bucket
    result = {} of Int64 => Bucket
    buckets.reverse_each do |bucket|
      break if bucket.index < first
      result[bucket.index] = bucket
    end
    result
  end

  # The file format: "LCH1", the number of series, then per series its mount name and, for each
  # resolution, the number of buckets and the buckets. Numbers are little-endian.
  private def write(io : IO) : Nil
    format = IO::ByteFormat::LittleEndian
    io << MAGIC
    io.write_bytes(@series.size.to_u32, format)
    @series.each do |mount, series|
      io.write_bytes(mount.bytesize.to_u16, format)
      io << mount
      series.each do |buckets|
        io.write_bytes(buckets.size.to_u32, format)
        buckets.each do |bucket|
          io.write_bytes(bucket.index, format)
          io.write_bytes(bucket.sum, format)
          io.write_bytes(bucket.samples, format)
          io.write_bytes(bucket.peak, format)
        end
      end
    end
  end

  private def load : Nil
    path = @path
    return unless path && File.exists?(path)
    series = File.open(path) { |file| read(file) }
    @mutex.synchronize { @series = series }
  rescue ex : IO::Error | ArgumentError
    Log.error { "Could not read the listener history from #{path}; starting empty: #{ex.message}" }
  end

  private def read(io : IO) : Hash(String, Array(Deque(Bucket)))
    format = IO::ByteFormat::LittleEndian
    raise ArgumentError.new("not a listener history file") unless io.read_string(MAGIC.bytesize) == MAGIC
    result = {} of String => Array(Deque(Bucket))
    io.read_bytes(UInt32, format).times do
      mount = io.read_string(io.read_bytes(UInt16, format))
      result[mount] = RESOLUTIONS.map do |resolution|
        count = io.read_bytes(UInt32, format)
        raise ArgumentError.new("too many buckets for #{mount}") if count > resolution.keep + 1
        buckets = Deque(Bucket).new(count.to_i)
        count.times do
          buckets << Bucket.new(io.read_bytes(Int64, format), io.read_bytes(Int64, format),
            io.read_bytes(Int32, format), io.read_bytes(Int32, format))
        end
        buckets
      end.to_a
    end
    result
  end
end
