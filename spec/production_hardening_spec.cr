require "./spec_helper"

private def start_hardening_server(config : Config) : Tuple(IcecastServer, Int32)
  config.host = "127.0.0.1"
  config.source_password = "secret"
  config.admin_password = "admin"
  listener = TCPServer.new("127.0.0.1", 0)
  port = listener.local_address.as(Socket::IPAddress).port
  server = IcecastServer.new(config)
  spawn server.serve(listener)
  Fiber.yield
  {server, port}
end

describe "production hardening" do
  it "applies source_timeout to plain TCP sources" do
    config = Config.new
    config.timeout = 30
    config.source_timeout = 1
    server, port = start_hardening_server(config)

    source = TCPSocket.new("127.0.0.1", port)
    source.print "SOURCE /idle.mp3 HTTP/1.0\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\n\r\n"
    read_head(source).should start_with("HTTP/1.0 200")
    wait_until { server.get_mount("/idle.mp3").try(&.has_source?) || false }

    wait_until(5.seconds) { server.get_mount("/idle.mp3").nil? }
  ensure
    source.try(&.close)
    server.try(&.stop)
  end

  it "does not count listeners against max_connections_per_ip, and caps them with max_listeners_per_ip" do
    config = Config.new
    config.max_connections_per_ip = 2
    config.max_listeners_per_ip = 3
    server, port = start_hardening_server(config)

    source = TCPSocket.new("127.0.0.1", port)
    source.print "SOURCE /live.mp3 HTTP/1.0\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\n\r\n"
    read_head(source).should start_with("HTTP/1.0 200")
    source.write(mp3_frame + mp3_frame)
    source.flush
    wait_until { server.get_mount("/live.mp3").try(&.has_source?) || false }

    listeners = Array.new(3) do
      listener = TCPSocket.new("127.0.0.1", port)
      listener.print "GET /live.mp3 HTTP/1.0\r\n\r\n"
      read_head(listener).should start_with("HTTP/1.0 200")
      listener
    end
    wait_until { server.get_mount("/live.mp3").try(&.listener_count) == 3 }

    api = TCPSocket.new("127.0.0.1", port)
    api.print "GET /status-json.xsl HTTP/1.0\r\n\r\n"
    read_head(api).should start_with("HTTP/1.0 200")
    api.close

    rejected = TCPSocket.new("127.0.0.1", port)
    rejected.print "GET /live.mp3 HTTP/1.0\r\n\r\n"
    read_head(rejected).should start_with("HTTP/1.0 429")
    rejected.close

    listeners.pop.close
    wait_until { server.get_mount("/live.mp3").try(&.listener_count) == 2 }
    wait_until { server.@listener_addresses["127.0.0.1"]? == 2 }
    server.@connections["127.0.0.1"].should eq(1)
  ensure
    listeners.try(&.each(&.close))
    source.try(&.close)
    server.try(&.stop)
  end

  it "forgets rate-limit history for addresses idle past the window" do
    config = Config.new
    config.rate_limit_window = 1
    server, port = start_hardening_server(config)
    server.@requests["203.0.113.9"] = [Time.instant - 5.seconds]

    client = TCPSocket.new("127.0.0.1", port)
    client.print "GET /status-json.xsl HTTP/1.0\r\n\r\n"
    read_head(client).should start_with("HTTP/1.0 200")

    server.@requests.has_key?("203.0.113.9").should be_false
    server.@requests.has_key?("127.0.0.1").should be_true
  ensure
    client.try(&.close)
    server.try(&.stop)
  end
end

describe Config do
  it "reports password settings left at the built-in default" do
    Config.new.default_password_settings.should eq(["admin_password", "source_password", "relay_password"])

    config = Config.from_yaml("admin_password: a\nsource_password: s\nrelay_password: r\n")
    config.default_password_settings.should be_empty
  end
end
