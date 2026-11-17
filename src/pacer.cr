# Sends a stream at its own rate. Each chunk is due when the bytes sent so far have played,
# counted from a fixed start, so the time spent sending and any oversleep don't add up
# the way they do when sleeping a chunk's length after each one.
struct Pacer
  # How far behind the pacer may fall (after a stall) before it starts again from now,
  # rather than sending everything it missed at once.
  MAX_LAG = 1.second

  @start : Time::Instant
  @sent = 0_i64

  def initialize(@bytes_per_second : Float64, now : Time::Instant = Time.instant)
    raise ArgumentError.new("Pacer rate must be positive") unless @bytes_per_second.positive?
    @start = now
  end

  # Counts *bytes* as sent and returns how long to wait before sending more.
  def sent(bytes : Int, now : Time::Instant = Time.instant) : Time::Span
    @sent += bytes
    due = @start + (@sent / @bytes_per_second).seconds
    wait = due - now
    if wait < -MAX_LAG
      @start = now
      @sent = 0_i64
      return Time::Span.zero
    end
    wait.positive? ? wait : Time::Span.zero
  end

  # Starts counting again from *now*, as after a pause.
  def restart(now : Time::Instant = Time.instant) : Nil
    @start = now
    @sent = 0_i64
  end
end
