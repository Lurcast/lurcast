require "./spec_helper"

private SOURCE_AUTH = "Basic #{Base64.strict_encode("source:secret")}"
private RELAY_AUTH  = "Basic #{Base64.strict_encode("relay:relay-pass")}"

private def scale_config : Config
  config = Config.new
  config.host = "127.0.0.1"
  config.source_password = "secret"
  config.admin_password = "admin"
  config.relay_password = "relay-pass"
  config.max_connections_per_ip = 50
  config
end

private def start_server(config : Config) : {IcecastServer, Int32, TCPSocket}
  listener = TCPServer.new("127.0.0.1", 0)
  port = listener.local_address.as(Socket::IPAddress).port
  server = IcecastServer.new(config)
  spawn server.serve(listener)
  Fiber.yield
  source = TCPSocket.new("127.0.0.1", port)
  source.print "PUT /live HTTP/1.1\r\nAuthorization: #{SOURCE_AUTH}\r\nContent-Type: audio/mpeg\r\nExpect: 100-continue\r\n\r\n"
  read_head(source).should start_with("HTTP/1.1 100")
  4.times { source.write(mp3_frame) }
  source.flush
  {server, port, source}
end

# Opens a listener and returns its socket with the response head.
private def listen(port : Int32, target = "/live", headers = "") : {TCPSocket, String}
  socket = TCPSocket.new("127.0.0.1", port)
  socket.read_timeout = 2.seconds
  socket.print "GET #{target} HTTP/1.0\r\n#{headers}\r\n"
  {socket, read_head(socket)}
end

private def listener_count(server : IcecastServer) : Int32
  server.get_mount("/live").try(&.listener_count) || 0
end

describe "Relays past listener limits" do
  it "lets a server relaying this one past the server, mount and per-address limits" do
    config = scale_config
    config.max_listeners = 1
    config.max_listeners_per_ip = 1
    server, port, source = start_server(config)
    sockets = [] of TCPSocket

    socket, head = listen(port)
    sockets << socket
    head.should start_with("HTTP/1.0 200")
    wait_until { listener_count(server) == 1 }

    socket, head = listen(port)
    sockets << socket
    head.should start_with("HTTP/1.0 503")

    socket, head = listen(port, headers: "Authorization: #{RELAY_AUTH}\r\n")
    sockets << socket
    head.should start_with("HTTP/1.0 200")
    wait_until { listener_count(server) == 2 }
  ensure
    sockets.try(&.each(&.close))
    source.try(&.close)
    server.try(&.stop)
  end
end

describe "Redirecting listeners when full" do
  it "sends listeners to the other servers in turn, and only once" do
    config = scale_config
    config.max_listeners = 1
    config.redirect_servers = ["http://a.example", "https://b.example:8443/"]
    server, port, source = start_server(config)
    sockets = [] of TCPSocket

    socket, head = listen(port)
    sockets << socket
    head.should start_with("HTTP/1.0 200")
    wait_until { listener_count(server) == 1 }

    socket, head = listen(port, "/live?token=abc")
    sockets << socket
    head.should start_with("HTTP/1.0 302")
    head.should contain("Location: http://a.example/live?token=abc&lurcast_redirect=1")

    socket, head = listen(port)
    sockets << socket
    head.should contain("Location: https://b.example:8443/live?lurcast_redirect=1")

    # Already redirected here: another full server doesn't send it on again.
    socket, head = listen(port, "/live?lurcast_redirect=1")
    sockets << socket
    head.should start_with("HTTP/1.0 503")
  ensure
    sockets.try(&.each(&.close))
    source.try(&.close)
    server.try(&.stop)
  end
end

describe "max_bandwidth_kbps" do
  it "turns away a listener who would take the server over its bandwidth" do
    config = scale_config
    config.max_bandwidth_kbps = 300 # room for two 128 kbit/s listeners
    server, port, source = start_server(config)
    wait_until { server.get_mount("/live").try(&.bitrate) == 128 }
    sockets = [] of TCPSocket

    2.times do |index|
      socket, head = listen(port)
      sockets << socket
      head.should start_with("HTTP/1.0 200")
      wait_until { listener_count(server) == index + 1 }
    end

    socket, head = listen(port)
    sockets << socket
    head.should start_with("HTTP/1.0 503")

    socket, head = listen(port, headers: "Authorization: #{RELAY_AUTH}\r\n")
    sockets << socket
    head.should start_with("HTTP/1.0 200")
  ensure
    sockets.try(&.each(&.close))
    source.try(&.close)
    server.try(&.stop)
  end
end

describe "Burst and queue in seconds" do
  it "sizes them from the bitrate the source declares" do
    mount = MountPoint.new("/s", 4096, 524_288, burst_seconds: 2.0, queue_seconds: 10.0)
    mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/mpeg", "Ice-Bitrate" => "128"})

    mount.@buffer.size.should eq(32_000)
    mount.@queue_size.should eq(160_000)
  end

  it "resizes them from the rate the source sends at, keeping the newest audio" do
    mount = MountPoint.new("/s", 65_536, 524_288, burst_seconds: 1.0, rate_window: 200.milliseconds)
    mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/mpeg"})
    10.times { mount.publish(mp3_frame) }
    sleep 250.milliseconds
    # The window closes with the next piece: 11 frames (4587 bytes) in a quarter second, some 18 KB/s.
    mount.publish(mp3_frame)

    mount.@buffer.size.should be_close(18_000, 6_000)
    burst = mount.initial_burst
    burst.size.should be > 0
    burst.size.should be <= mount.@buffer.size
  end

  it "keeps a byte queue at least as big as the burst" do
    mount = MountPoint.new("/s", 4096, 16_384, burst_seconds: 5.0)
    mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/mpeg", "Ice-Bitrate" => "128"})
    mount.@buffer.size.should eq(16_384)
  end
end

describe Config do
  it "checks the scale-out settings" do
    config = scale_config
    config.redirect_servers = ["https://relay.example.com/"]
    config.max_bandwidth_kbps = 1_000_000
    config.burst_seconds = 2.0
    config.queue_seconds = 30.0
    config.validate!

    config.redirect_servers = ["https://relay.example.com/live"]
    expect_raises(ArgumentError, /redirect_servers entry .* must be an http or https URL with no path/) { config.validate! }
    config.redirect_servers = ["ftp://relay.example.com"]
    expect_raises(ArgumentError, /redirect_servers/) { config.validate! }
    config.redirect_servers = [] of String

    config.max_bandwidth_kbps = 0
    expect_raises(ArgumentError, /max_bandwidth_kbps must be positive/) { config.validate! }
    config.max_bandwidth_kbps = nil

    config.burst_seconds = 40.0
    expect_raises(ArgumentError, /burst_seconds must not exceed queue_seconds/) { config.validate! }
    config.burst_seconds = 0.0
    expect_raises(ArgumentError, /between 0 and 600/) { config.validate! }
  end

  it "takes a mount's own sizes, in either unit, before the global seconds" do
    config = scale_config
    config.burst_seconds = 2.0
    config.queue_seconds = 30.0
    config.mounts = {
      "/bytes"   => MountConfig.new(burst_size: 8192, queue_size: 65_536),
      "/seconds" => MountConfig.new(burst_seconds: 1.0),
    }

    config.burst_seconds_for("/other").should eq(2.0)
    config.burst_seconds_for("/bytes").should be_nil
    config.queue_seconds_for("/bytes").should be_nil
    config.burst_seconds_for("/seconds").should eq(1.0)
    config.queue_seconds_for("/seconds").should eq(30.0)
  end
end
