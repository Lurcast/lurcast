# Load test: one paced 128 kbps MP3 source and N concurrent listeners against a running server.
#
#   crystal build --release bench/load_test.cr -o bin/load_test
#   bin/load_test --port 8000 --password secret --listeners 2000 --duration 60
#
# The server must allow the load: raise max_listeners, rate_limit, and (if set) max_listeners_per_ip.
require "base64"
require "option_parser"
require "socket"

host = "127.0.0.1"
port = 8000
mount = "/load.mp3"
password = "hackme"
listener_count = 1000
duration = 30
ramp = 5

OptionParser.parse do |parser|
  parser.on("--host=HOST", "Server host") { |value| host = value }
  parser.on("--port=PORT", "Server port") { |value| port = value.to_i }
  parser.on("--mount=MOUNT", "Mount to create") { |value| mount = value }
  parser.on("--password=PASSWORD", "Source password") { |value| password = value }
  parser.on("--listeners=N", "Concurrent listeners") { |value| listener_count = value.to_i }
  parser.on("--duration=SECONDS", "Measurement time after ramp-up") { |value| duration = value.to_i }
  parser.on("--ramp=SECONDS", "Time to connect all listeners") { |value| ramp = value.to_i }
end

FRAME_BYTES    = 417
FRAME_DURATION = 1152.0 / 44_100
BITRATE_BYTES  = 16_000.0 # 128 kbps

frame = Bytes.new(FRAME_BYTES, 0x55_u8)
Bytes[0xff, 0xfb, 0x90, 0x64].copy_to(frame)

source = TCPSocket.new(host, port)
auth = Base64.strict_encode("source:#{password}")
source << "SOURCE #{mount} HTTP/1.0\r\nAuthorization: Basic #{auth}\r\nContent-Type: audio/mpeg\r\nIce-Bitrate: 128\r\n\r\n"
source.flush
status = source.gets || abort "source: no response"
abort "source rejected: #{status}" unless status.includes?(" 200")
until (source.gets || "").blank?
end

spawn do
  started = Time.instant
  sent = 0
  loop do
    source.write(frame)
    sent += 1
    ahead = started + (sent * FRAME_DURATION).seconds - Time.instant
    sleep ahead if ahead.positive?
  end
rescue ex
  STDERR.puts "source stopped: #{ex.message}"
end
sleep 1.second

received = Array(Int64).new(listener_count, 0_i64)
measured_from = Array(Int64).new(listener_count, 0_i64)
connected = Atomic(Int32).new(0)
failed = Atomic(Int32).new(0)
dropped = Atomic(Int32).new(0)
measuring = Atomic(Bool).new(false)

listener_count.times do |index|
  spawn do
    socket = TCPSocket.new(host, port)
    socket.read_timeout = 10.seconds
    socket << "GET #{mount} HTTP/1.0\r\n\r\n"
    socket.flush
    head = socket.gets
    unless head && head.includes?(" 200")
      failed.add(1)
      next
    end
    until (socket.gets || "").blank?
    end
    connected.add(1)
    buffer = Bytes.new(8192)
    loop do
      count = socket.read(buffer)
      if count == 0
        dropped.add(1)
        break
      end
      received[index] += count
      measured_from[index] = received[index] unless measuring.get
    end
  rescue
    failed.add(1)
  ensure
    socket.try(&.close)
  end
  sleep (ramp.to_f / listener_count).seconds
end

sleep 2.seconds
puts "ramped: #{connected.get} connected, #{failed.get} failed"
measuring.set(true)
sleep duration.seconds

rates = received.zip(measured_from).map { |total, before| (total - before) / duration }.sort!
expected = BITRATE_BYTES
healthy = rates.count { |rate| rate >= expected * 0.95 }
puts "listeners: #{connected.get} connected, #{failed.get} failed, #{dropped.get} dropped"
puts "per-listener throughput over #{duration}s (expected #{expected.to_i} B/s):"
puts "  min #{rates.first.to_i} B/s, p50 #{rates[rates.size // 2].to_i} B/s, max #{rates.last.to_i} B/s"
puts "  #{healthy}/#{listener_count} listeners at >= 95% of the stream rate"
exit(healthy == listener_count ? 0 : 1)
