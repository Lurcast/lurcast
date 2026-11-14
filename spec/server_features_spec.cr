require "./spec_helper"

describe IcecastServer do
  it "exposes a versioned JSON station API with source, song, and MP3 details" do
    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "secret"
    config.admin_password = "admin"
    config.public_url = "https://radio.example"
    config.max_connections_per_ip = 10
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    Fiber.yield

    source = TCPSocket.new("127.0.0.1", port)
    source.print "PUT /radio.mp3 HTTP/1.1\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\nIce-Name: Spec Radio\r\nIce-Description: Independent radio\r\nIce-Genre: Jazz\r\nIce-URL: https://radio.example/about\r\nExpect: 100-continue\r\n\r\n"
    read_head(source).should start_with("HTTP/1.1 100")
    source.write(mp3_frame + mp3_frame)
    source.flush
    wait_until { !server.get_mount("/radio.mp3").try(&.mp3_info).nil? }

    metadata = TCPSocket.new("127.0.0.1", port)
    metadata.print "GET /admin/metadata?mount=/radio.mp3&song=Artist+-+Song HTTP/1.0\r\nAuthorization: Basic YWRtaW46YWRtaW4=\r\n\r\n"
    read_head(metadata).should start_with("HTTP/1.0 200")
    metadata.close

    api = TCPSocket.new("127.0.0.1", port)
    api.print "GET /api/v1/stations HTTP/1.0\r\n\r\n"
    api_head = read_head(api)
    api_head.should start_with("HTTP/1.0 200")
    response = JSON.parse(api.gets_to_end)
    response["api_version"].as_s.should eq("1")
    response["server"]["sources"].as_i.should eq(1)
    station = response["stations"].as_a.first
    station["mount"].as_s.should eq("/radio.mp3")
    station["listen_url"].as_s.should eq("https://radio.example/radio.mp3")
    station["source_protocol"].as_s.should eq("icecast")
    station["station"]["name"].as_s.should eq("Spec Radio")
    station["station"]["description"].as_s.should eq("Independent radio")
    station["now_playing"]["song"].as_s.should eq("Artist - Song")
    station["stream"]["bitrate_kbps"].as_i.should eq(128)
    station["stream"]["sample_rate_hz"].as_i.should eq(44_100)
    station["stream"]["mpeg_version"].as_s.should eq("1")
    station["stream"]["mpeg_layer"].as_i.should eq(3)

    icecast_api = TCPSocket.new("127.0.0.1", port)
    icecast_api.print "GET /status-json.xsl HTTP/1.0\r\n\r\n"
    read_head(icecast_api).should start_with("HTTP/1.0 200")
    icecast_stats = JSON.parse(icecast_api.gets_to_end)["icestats"]
    icecast_stats["server_id"].as_s.should eq(IcecastServer::SERVER_ID)
    icecast_stats["sources"].as_i.should eq(1)
    icecast_source = icecast_stats["source"].as_a.first
    icecast_source["mount"].as_s.should eq("/radio.mp3")
    icecast_source["name"].as_s.should eq("Spec Radio")
    icecast_source["title"].as_s.should eq("Artist - Song")

    update_body = {name: "Updated Radio", description: "Community radio", genre: "Soul", listed: true, current_song: "New Artist - New Song"}.to_json
    unauthorized_update = TCPSocket.new("127.0.0.1", port)
    unauthorized_update.print "PATCH /api/v1/stations/radio.mp3 HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: #{update_body.bytesize}\r\n\r\n#{update_body}"
    unauthorized_head = read_head(unauthorized_update)
    unauthorized_head.should start_with("HTTP/1.0 401")
    unauthorized_head.should contain("Content-Type: application/json")
    JSON.parse(unauthorized_update.gets_to_end)["error"].as_s.should eq("Authentication required")
    unauthorized_update.close

    invalid_body = {unknown: true}.to_json
    invalid_update = TCPSocket.new("127.0.0.1", port)
    invalid_update.print "PATCH /api/v1/stations/radio.mp3 HTTP/1.1\r\nAuthorization: Basic YWRtaW46YWRtaW4=\r\nContent-Type: application/json\r\nContent-Length: #{invalid_body.bytesize}\r\n\r\n#{invalid_body}"
    read_head(invalid_update).should start_with("HTTP/1.0 400")
    JSON.parse(invalid_update.gets_to_end)["error"].as_s.should contain("Unknown JSON attribute")
    invalid_update.close

    update = TCPSocket.new("127.0.0.1", port)
    update.print "PATCH /api/v1/stations/radio.mp3 HTTP/1.1\r\nAuthorization: Basic YWRtaW46YWRtaW4=\r\nContent-Type: application/json\r\nContent-Length: #{update_body.bytesize}\r\n\r\n#{update_body}"
    read_head(update).should start_with("HTTP/1.0 200")
    update.close

    updated_api = TCPSocket.new("127.0.0.1", port)
    updated_api.print "GET /api/v1/stations HTTP/1.0\r\n\r\n"
    read_head(updated_api).should start_with("HTTP/1.0 200")
    updated = JSON.parse(updated_api.gets_to_end)["stations"].as_a.first
    updated["station"]["name"].as_s.should eq("Updated Radio")
    updated["station"]["description"].as_s.should eq("Community radio")
    updated["station"]["genre"].as_s.should eq("Soul")
    updated["station"]["listed"].as_bool.should be_true
    updated["now_playing"]["song"].as_s.should eq("New Artist - New Song")

    head_api = TCPSocket.new("127.0.0.1", port)
    head_api.print "HEAD /api/v1/stations HTTP/1.0\r\n\r\n"
    head_response = read_head(head_api)
    head_response.should start_with("HTTP/1.0 200")
    head_response.should match(/Content-Length: [1-9][0-9]*/)
    head_api.gets_to_end.should be_empty

    mutation_head = TCPSocket.new("127.0.0.1", port)
    mutation_head.print "HEAD /admin/killsource?mount=/radio.mp3 HTTP/1.0\r\nAuthorization: Basic YWRtaW46YWRtaW4=\r\n\r\n"
    read_head(mutation_head).should start_with("HTTP/1.0 405")
    server.get_mount("/radio.mp3").try(&.has_source?).should be_true

    preflight = TCPSocket.new("127.0.0.1", port)
    preflight.print "OPTIONS /api/v1/stations/radio.mp3 HTTP/1.0\r\nOrigin: https://app.example\r\n\r\n"
    preflight_response = read_head(preflight)
    preflight_response.should contain("Access-Control-Allow-Origin: *")
    preflight_response.should contain("Access-Control-Allow-Methods: GET, HEAD, PUT, SOURCE, POST, PATCH, OPTIONS")
    preflight_response.should contain("Access-Control-Allow-Headers: Authorization, Content-Type, Icy-MetaData")
  ensure
    source.try(&.close)
    metadata.try(&.close)
    api.try(&.close)
    icecast_api.try(&.close)
    unauthorized_update.try(&.close)
    invalid_update.try(&.close)
    update.try(&.close)
    updated_api.try(&.close)
    head_api.try(&.close)
    mutation_head.try(&.close)
    preflight.try(&.close)
    server.try(&.stop)
  end

  it "finishes an HTTP PUT only after the source body ends" do
    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "secret"
    config.admin_password = "admin"
    config.max_connections_per_ip = 10
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    Fiber.yield

    source = TCPSocket.new("127.0.0.1", port)
    source.read_timeout = 100.milliseconds
    source.print "PUT /timed HTTP/1.1\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\nContent-Length: 4\r\nExpect: 100-continue\r\n\r\n"
    read_head(source).should start_with("HTTP/1.1 100")
    expect_raises(IO::TimeoutError) { source.gets }

    source.read_timeout = 2.seconds
    source.write(Bytes[1, 2, 3, 4])
    read_head(source).should start_with("HTTP/1.0 200")
  ensure
    source.try(&.close)
    server.try(&.stop)
  end

  it "builds each mount with its configured burst and queue sizes" do
    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "secret"
    config.admin_password = "admin"
    config.max_connections_per_ip = 10
    burst_size = mp3_frame.size * 2
    config.mounts = {"/short" => MountConfig.new(burst_size: burst_size, queue_size: burst_size)}
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    Fiber.yield

    source = TCPSocket.new("127.0.0.1", port)
    source.print "PUT /short HTTP/1.1\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\nExpect: 100-continue\r\n\r\n"
    read_head(source).should start_with("HTTP/1.1 100")
    source.write(mp3_frame(1_u8) + mp3_frame(1_u8) + mp3_frame(2_u8) + mp3_frame(2_u8))
    source.flush

    wait_until { server.get_mount("/short").try(&.initial_burst.size) == burst_size }
    server.get_mount("/short").try(&.initial_burst).should eq(mp3_frame(2_u8) + mp3_frame(2_u8))
  ensure
    source.try(&.close)
    server.try(&.stop)
  end

  it "streams a chunked Icecast source through Crystal's HTTP body IO" do
    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "secret"
    config.admin_password = "admin"
    config.max_connections_per_ip = 10
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    Fiber.yield

    source = TCPSocket.new("127.0.0.1", port)
    source.print "PUT /chunked HTTP/1.1\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n"
    read_head(source).should start_with("HTTP/1.1 100")

    listener = TCPSocket.new("127.0.0.1", port)
    listener.read_timeout = 2.seconds
    listener.print "GET /chunked HTTP/1.0\r\n\r\n"
    read_head(listener).should start_with("HTTP/1.0 200")

    audio = mp3_frame + mp3_frame
    source.print "#{audio.size.to_s(16)}\r\n"
    source.write(audio)
    source.print "\r\n"
    source.flush
    received = Bytes.new(audio.size)
    listener.read_fully(received)
    received.should eq(audio)
    source.print "0\r\n\r\n"
    source.flush
    read_head(source).should start_with("HTTP/1.0 200")
  ensure
    source.try(&.close)
    listener.try(&.close)
    server.try(&.stop)
  end

  it "accepts a legacy Icecast SOURCE upload" do
    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "secret"
    config.admin_password = "admin"
    config.max_connections_per_ip = 10
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    Fiber.yield

    source = TCPSocket.new("127.0.0.1", port)
    source.print "SOURCE /legacy HTTP/1.0\r\nAuthorization: bAsIc c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\nX-Audiocast-Name: Legacy Radio\r\nX-Audiocast-Public: 1\r\n\r\n"
    read_head(source).should start_with("HTTP/1.0 200")
    mount = server.get_mount("/legacy") || raise "expected legacy mount"
    mount.source_protocol.should eq(SourceProtocol::Icecast)
    mount.station_details.name.should eq("Legacy Radio")
    mount.listed.should be_true
  ensure
    source.try(&.close)
    server.try(&.stop)
  end

  it "accepts a SHOUTcast v1 source on the dedicated source port" do
    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "secret"
    config.admin_password = "admin"
    config.shoutcast_mount = "/shout"
    config.max_connections_per_ip = 10
    http_listener = TCPServer.new("127.0.0.1", 0)
    shout_listener = TCPServer.new("127.0.0.1", 0)
    http_port = http_listener.local_address.as(Socket::IPAddress).port
    shout_port = shout_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    spawn server.serve_shoutcast(shout_listener)
    Fiber.yield

    source = TCPSocket.new("127.0.0.1", shout_port)
    source.print "secret\r\n"
    source.gets.should eq("OK2")
    source.gets.should eq("icy-caps:11")
    source.gets.should eq("")
    source.print "icy-name: Legacy Radio\r\nicy-genre: Rock\r\n\r\n"
    wait_until { server.get_mount("/shout").try(&.source_protocol) == SourceProtocol::ShoutcastV1 }

    metadata = TCPSocket.new("127.0.0.1", http_port)
    metadata.print "GET /admin.cgi?pass=secret&mode=updinfo&song=Legacy+Artist+-+Song HTTP/1.0\r\n\r\n"
    read_head(metadata).should start_with("HTTP/1.0 200")
    wait_until { server.get_mount("/shout").try(&.current_song) == "Legacy Artist - Song" }

    listener = TCPSocket.new("127.0.0.1", http_port)
    listener.read_timeout = 2.seconds
    listener.print "GET /; HTTP/1.0\r\n\r\n"
    read_head(listener).should start_with("HTTP/1.0 200")

    audio = mp3_frame + mp3_frame
    source.write(audio)
    source.flush
    received = Bytes.new(audio.size)
    listener.read_fully(received)
    received.should eq(audio)
  ensure
    source.try(&.close)
    metadata.try(&.close)
    listener.try(&.close)
    server.try(&.stop)
  end

  it "accepts an encrypted SHOUTcast v2 Ultravox source" do
    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "secret"
    config.admin_password = "admin"
    config.shoutcast_mounts = {2 => "/shout-v2"}
    config.max_connections_per_ip = 10
    http_listener = TCPServer.new("127.0.0.1", 0)
    shout_listener = TCPServer.new("127.0.0.1", 0)
    http_port = http_listener.local_address.as(Socket::IPAddress).port
    shout_port = shout_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    spawn server.serve_shoutcast(shout_listener)
    Fiber.yield

    invalid = TCPSocket.new("127.0.0.1", shout_port)
    invalid.read_timeout = 2.seconds
    invalid.write(uvox_frame(0x1001_u16, "bad\0".to_slice))
    read_uvox(invalid).should eq({0x1001_u16, "NAK:2.1:Parse Error\0".to_slice})
    invalid.close

    credentials = "2.1:2:220ed13fb6e178b3:320df7c171d7dc60\0"
    repeated = TCPSocket.new("127.0.0.1", shout_port)
    repeated.read_timeout = 2.seconds
    repeated.write(uvox_frame(0x1009_u16, "2.1\0".to_slice))
    read_uvox(repeated)
    repeated.write(uvox_frame(0x1001_u16, credentials.to_slice))
    read_uvox(repeated)
    repeated.write(uvox_frame(0x1001_u16, credentials.to_slice))
    read_uvox(repeated).should eq({0x1001_u16, "NAK:Sequence Error\0".to_slice})
    repeated.close

    source = TCPSocket.new("127.0.0.1", shout_port)
    source.read_timeout = 2.seconds
    source.write(uvox_frame(0x1009_u16, "2.1\0".to_slice))
    read_uvox(source).should eq({0x1009_u16, "ACK:foobar\0".to_slice})

    source.write(uvox_frame(0x1001_u16, credentials.to_slice))
    read_uvox(source).should eq({0x1001_u16, "ACK:2.1:Allow\0".to_slice})

    {
      0x1040_u16 => "audio/mpeg\0",
      0x1002_u16 => "128:128\0",
      0x1003_u16 => "64:32\0",
      0x1008_u16 => "16377:4096\0",
      0x1100_u16 => "Ultravox Radio\0",
    }.each do |type, payload|
      source.write(uvox_frame(type, payload.to_slice))
      response_type, response = read_uvox(source)
      response_type.should eq(type)
      String.new(response).should start_with("ACK")
    end

    source.write(uvox_frame(0x1004_u16))
    read_uvox(source).should eq({0x1004_u16, "ACK:Data transfer mode\0".to_slice})
    server.get_mount("/shout-v2").try(&.source_protocol).should eq(SourceProtocol::ShoutcastV2)

    listener = TCPSocket.new("127.0.0.1", http_port)
    listener.read_timeout = 2.seconds
    listener.print "GET /stream/2 HTTP/1.0\r\n\r\n"
    response = read_head(listener)
    response.should start_with("HTTP/1.0 200")
    response.should contain("icy-name: Ultravox Radio")

    source.write(uvox_frame(0x3902_u16, uvox_metadata("<metadata><TIT2>Artist - Song</TIT2></metadata>")))
    audio = mp3_frame + mp3_frame
    source.write(uvox_frame(0x7000_u16, audio))
    received = Bytes.new(audio.size)
    listener.read_fully(received)
    received.should eq(audio)
    wait_until { server.get_mount("/shout-v2").try(&.current_song) == "Artist - Song" }

    source.write(uvox_frame(0x1005_u16))
  ensure
    invalid.try(&.close)
    repeated.try(&.close)
    source.try(&.close)
    listener.try(&.close)
    server.try(&.stop)
  end

  it "moves connected listeners to a configured fallback when a source ends" do
    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "secret"
    config.admin_password = "admin"
    config.max_connections_per_ip = 10
    config.set_fallback("/live", "/backup")
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    Fiber.yield

    backup = TCPSocket.new("127.0.0.1", port)
    backup.print "PUT /backup HTTP/1.1\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\nExpect: 100-continue\r\n\r\n"
    read_head(backup).should start_with("HTTP/1.1 100")
    live = TCPSocket.new("127.0.0.1", port)
    live.print "PUT /live HTTP/1.1\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\nExpect: 100-continue\r\n\r\n"
    read_head(live).should start_with("HTTP/1.1 100")

    listener = TCPSocket.new("127.0.0.1", port)
    listener.read_timeout = 2.seconds
    listener.print "GET /live HTTP/1.0\r\n\r\n"
    read_head(listener).should start_with("HTTP/1.0 200")
    live_audio = mp3_frame(1_u8) + mp3_frame(1_u8)
    live.write(live_audio)
    first = Bytes.new(live_audio.size)
    listener.read_fully(first)
    first.should eq(live_audio)

    killer = TCPSocket.new("127.0.0.1", port)
    killer.print "GET /admin/killsource?mount=/live HTTP/1.0\r\nAuthorization: Basic YWRtaW46YWRtaW4=\r\n\r\n"
    read_head(killer).should start_with("HTTP/1.0 200")
    killer.close
    wait_until { server.get_mount("/live").nil? }
    # Outlast the listener loop's poll interval: a moved listener must stay connected.
    sleep 600.milliseconds
    backup_audio = mp3_frame(2_u8) + mp3_frame(2_u8)
    backup.write(backup_audio)
    second = Bytes.new(backup_audio.size)
    listener.read_fully(second)
    second.should eq(backup_audio)
  ensure
    backup.try(&.close)
    live.try(&.close)
    killer.try(&.close)
    listener.try(&.close)
    server.try(&.stop)
  end

  it "uses a mount fallback when that mount reaches its listener limit" do
    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "secret"
    config.admin_password = "admin"
    config.max_connections_per_ip = 10
    config.mounts = {
      "/live" => MountConfig.new(
        max_listeners: 1,
        fallback: "/backup",
        fallback_when_full: true,
      ),
    }
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    Fiber.yield

    live = TCPSocket.new("127.0.0.1", port)
    live.print "PUT /live HTTP/1.1\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\nExpect: 100-continue\r\n\r\n"
    read_head(live).should start_with("HTTP/1.1 100")
    backup = TCPSocket.new("127.0.0.1", port)
    backup.print "PUT /backup HTTP/1.1\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\nExpect: 100-continue\r\n\r\n"
    read_head(backup).should start_with("HTTP/1.1 100")

    first = TCPSocket.new("127.0.0.1", port)
    first.read_timeout = 2.seconds
    first.print "GET /live HTTP/1.0\r\n\r\n"
    read_head(first).should start_with("HTTP/1.0 200")
    wait_until { server.get_mount("/live").try(&.listener_count) == 1 }

    second = TCPSocket.new("127.0.0.1", port)
    second.read_timeout = 2.seconds
    second.print "GET /live HTTP/1.0\r\n\r\n"
    read_head(second).should start_with("HTTP/1.0 200")
    wait_until { server.get_mount("/backup").try(&.listener_count) == 1 }

    live_audio = mp3_frame(1_u8) + mp3_frame(1_u8)
    backup_audio = mp3_frame(2_u8) + mp3_frame(2_u8)
    live.write(live_audio)
    backup.write(backup_audio)
    live.flush
    backup.flush

    received = Bytes.new(live_audio.size)
    first.read_fully(received)
    received.should eq(live_audio)
    second.read_fully(received)
    received.should eq(backup_audio)
  ensure
    live.try(&.close)
    backup.try(&.close)
    first.try(&.close)
    second.try(&.close)
    server.try(&.stop)
  end

  it "disconnects listeners after a mount-specific duration" do
    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "secret"
    config.admin_password = "admin"
    config.max_connections_per_ip = 10
    config.mounts = {"/limited" => MountConfig.new(max_listener_duration: 1)}
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    Fiber.yield

    source = TCPSocket.new("127.0.0.1", port)
    source.print "PUT /limited HTTP/1.1\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\nExpect: 100-continue\r\n\r\n"
    read_head(source).should start_with("HTTP/1.1 100")
    listener = TCPSocket.new("127.0.0.1", port)
    listener.print "GET /limited HTTP/1.0\r\n\r\n"
    read_head(listener).should start_with("HTTP/1.0 200")
    wait_until { server.get_mount("/limited").try(&.listener_count) == 1 }

    wait_until(2.seconds) { server.get_mount("/limited").try(&.listener_count) == 0 }
  ensure
    source.try(&.close)
    listener.try(&.close)
    server.try(&.stop)
  end

  it "loops a fallback file until the requested source returns" do
    webroot = File.tempname("lurcast-fallback", nil)
    Dir.mkdir(webroot)
    fallback_audio = Bytes.new(417, 7_u8)
    Bytes[0xff, 0xfb, 0x90, 0x64].copy_to(fallback_audio)
    File.write(File.join(webroot, "backup.mp3"), fallback_audio)

    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "secret"
    config.admin_password = "admin"
    config.max_connections_per_ip = 10
    config.max_sources = 1
    config.webroot = webroot
    config.set_fallback("/live", "/backup.mp3")
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    Fiber.yield

    source = TCPSocket.new("127.0.0.1", port)
    source.print "PUT /live HTTP/1.1\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\nExpect: 100-continue\r\n\r\n"
    read_head(source).should start_with("HTTP/1.1 100")

    listener = TCPSocket.new("127.0.0.1", port)
    listener.read_timeout = 2.seconds
    listener.print "GET /live HTTP/1.0\r\n\r\n"
    read_head(listener).should start_with("HTTP/1.0 200")
    source.close

    received = Bytes.new(fallback_audio.size)
    listener.read_fully(received)
    received.should eq(fallback_audio)
    wait_until { server.get_mount("/backup.mp3").try(&.listener_count) == 1 }
    server.get_mount("/backup.mp3").try(&.source_protocol).should eq(SourceProtocol::File)

    replacement = TCPSocket.new("127.0.0.1", port)
    replacement.print "PUT /live HTTP/1.1\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\nExpect: 100-continue\r\n\r\n"
    read_head(replacement).should start_with("HTTP/1.1 100")
    wait_until { server.get_mount("/live").try(&.listener_count) == 1 }
    server.get_mount("/backup.mp3").try(&.listener_count).should eq(0)
  ensure
    source.try(&.close)
    replacement.try(&.close)
    listener.try(&.close)
    server.try(&.stop)
    webroot.try { |path| FileUtils.rm_rf(path) }
  end

  it "pulls and reconnects a configured HTTP relay" do
    upstream_listener = TCPServer.new("127.0.0.1", 0)
    upstream_port = upstream_listener.local_address.as(Socket::IPAddress).port
    upstream_connections = Channel(TCPSocket).new
    audio = mp3_frame + mp3_frame
    spawn do
      while upstream = upstream_listener.accept?
        read_head(upstream)
        upstream.print "HTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\nIcy-Name: Upstream\r\nIcy-MetaInt: #{audio.size}\r\n\r\n"
        upstream.flush
        upstream_connections.send(upstream)
      end
    end

    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "secret"
    config.admin_password = "admin"
    config.max_connections_per_ip = 10
    config.relays = [RelayConfig.new("http://127.0.0.1:#{upstream_port}/upstream", "/relay")]
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    upstream = receive(upstream_connections)
    wait_until { server.get_mount("/relay").try(&.source_protocol) == SourceProtocol::Relay }

    listener = TCPSocket.new("127.0.0.1", port)
    listener.read_timeout = 2.seconds
    listener.print "GET /relay HTTP/1.0\r\nIcy-MetaData: 1\r\n\r\n"
    listener_head = read_head(listener)
    listener_head.should start_with("HTTP/1.0 200")
    listener_head.should contain("icy-metaint: #{audio.size}")
    upstream.write(audio)
    metadata = "StreamTitle='Relay Artist - Song';"
    blocks = (metadata.bytesize + 15) // 16
    upstream.write_byte(blocks.to_u8)
    upstream.write(metadata.to_slice)
    upstream.write(Bytes.new(blocks * 16 - metadata.bytesize))
    upstream.flush
    received = Bytes.new(audio.size)
    listener.read_fully(received)
    received.should eq(audio)
    wait_until { server.get_mount("/relay").try(&.current_song) == "Relay Artist - Song" }

    upstream.close
    replacement = receive(upstream_connections, 7.seconds)
    replacement.closed?.should be_false
  ensure
    upstream.try(&.close)
    replacement.try(&.close)
    listener.try(&.close)
    upstream_listener.try(&.close)
    server.try(&.stop)
  end

  it "discovers master relays and starts them on demand" do
    upstream_listener = TCPServer.new("127.0.0.1", 0)
    upstream_port = upstream_listener.local_address.as(Socket::IPAddress).port
    upstream_requests = Channel(String).new(10)
    stream_connections = Channel(TCPSocket).new
    allow_stale_listing = Channel(Nil).new(1)
    listing_count = 0
    spawn do
      while socket = upstream_listener.accept?
        head = read_head(socket)
        upstream_requests.send(head)
        if head.starts_with?("GET /admin/streamlist.txt ")
          listing_count += 1
          allow_stale_listing.receive if listing_count == 2
          body = listing_count == 1 ? "/master\n" : ""
          socket.print "HTTP/1.0 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
          socket.close
        else
          socket.print "HTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\nIcy-Name: Master Radio\r\n\r\n"
          socket.flush
          stream_connections.send(socket)
        end
      end
    end

    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "secret"
    config.admin_password = "admin"
    config.max_connections_per_ip = 10
    config.master_url = "http://127.0.0.1:#{upstream_port}"
    config.master_username = "relay"
    config.master_password = "master-secret"
    config.master_update_interval = 1
    config.relays_on_demand = true
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)

    listing_request = receive(upstream_requests)
    listing_request.should contain("Authorization: Basic cmVsYXk6bWFzdGVyLXNlY3JldA==")
    select
    when request = upstream_requests.receive
      fail "unexpected eager relay request: #{request.each_line.first}"
    when timeout(100.milliseconds)
    end

    listener = TCPSocket.new("127.0.0.1", port)
    listener.read_timeout = 2.seconds
    listener.print "GET /master HTTP/1.0\r\n\r\n"
    stream_request = receive(upstream_requests)
    stream_request.should start_with("GET /master ")
    upstream = receive(stream_connections)
    read_head(listener).should start_with("HTTP/1.0 200")

    audio = mp3_frame + mp3_frame
    upstream.write(audio)
    upstream.flush
    received = Bytes.new(audio.size)
    listener.read_fully(received)
    received.should eq(audio)

    upstream.close
    wait_until { server.get_mount("/master").nil? }
    direct = TCPSocket.new("127.0.0.1", port)
    direct.print "PUT /master HTTP/1.1\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\nExpect: 100-continue\r\n\r\n"
    read_head(direct).should start_with("HTTP/1.1 100")

    allow_stale_listing.send(nil)
    receive(upstream_requests, 2.seconds).should start_with("GET /admin/streamlist.txt ")
    sleep 100.milliseconds
    server.get_mount("/master").try(&.has_source?).should be_true

    direct_listener = TCPSocket.new("127.0.0.1", port)
    direct_listener.read_timeout = 2.seconds
    direct_listener.print "GET /master HTTP/1.0\r\n\r\n"
    read_head(direct_listener).should start_with("HTTP/1.0 200")
    direct.write(audio)
    direct.flush
    direct_listener.read_fully(received)
    received.should eq(audio)
  ensure
    upstream.try(&.close)
    direct.try(&.close)
    listener.try(&.close)
    direct_listener.try(&.close)
    upstream_listener.try(&.close)
    server.try(&.stop)
  end

  it "uses an external URL for source and listener authentication lifecycle" do
    auth_listener = TCPServer.new("127.0.0.1", 0)
    auth_port = auth_listener.local_address.as(Socket::IPAddress).port
    auth_requests = Channel(HTTP::Params).new(10)
    spawn do
      while socket = auth_listener.accept?
        head = read_head(socket)
        content_length = head.each_line.find(&.downcase.starts_with?("content-length:"))
          .try(&.partition(':')[2].strip.to_i) || 0
        body = Bytes.new(content_length)
        socket.read_fully(body)
        params = HTTP::Params.parse(String.new(body))
        auth_requests.send(params)
        socket.print "HTTP/1.0 200 OK\r\nContent-Length: 0\r\nIcecast-Auth-User: 1\r\n\r\n"
        socket.close
      end
    end

    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "local-password-is-not-used"
    config.admin_password = "admin"
    config.plugins = {"url_auth" => YAML.parse("url: http://127.0.0.1:#{auth_port}/auth")}
    config.max_connections_per_ip = 10
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    Fiber.yield

    source = TCPSocket.new("127.0.0.1", port)
    source.print "PUT /external HTTP/1.1\r\nAuthorization: Basic ZGo6YW55dGhpbmc=\r\nContent-Type: audio/mpeg\r\nExpect: 100-continue\r\n\r\n"
    read_head(source).should start_with("HTTP/1.1 100")
    receive(auth_requests)["action"].should eq("stream_auth")
    receive(auth_requests)["action"].should eq("mount_add")

    metadata = TCPSocket.new("127.0.0.1", port)
    metadata.print "GET /admin/metadata?mount=/external&mode=updinfo&song=External+Song HTTP/1.0\r\nAuthorization: Basic ZGo6YW55dGhpbmc=\r\n\r\n"
    read_head(metadata).should start_with("HTTP/1.0 200")
    metadata_auth = receive(auth_requests)
    metadata_auth["action"].should eq("stream_auth")
    metadata_auth["admin"].should eq("1")

    listener = TCPSocket.new("127.0.0.1", port)
    listener.read_timeout = 2.seconds
    listener.print "GET /external HTTP/1.0\r\nAuthorization: Basic bGlzdGVuZXI6YW55dGhpbmc=\r\nUser-Agent: Spec Player\r\n\r\n"
    read_head(listener).should start_with("HTTP/1.0 200")
    listener_add = receive(auth_requests)
    listener_add["action"].should eq("listener_add")
    listener_add["mount"].should eq("/external")
    listener_add["user"].should eq("listener")
    listener_add["agent"].should eq("Spec Player")

    listener.close
    source.write(Bytes[1, 2, 3, 4])
    source.flush
    wait_until { server.streams.sum(&.listener_count) == 0 }
    source.close

    final_actions = [receive(auth_requests)["action"], receive(auth_requests)["action"]]
    final_actions.sort.should eq(["listener_remove", "mount_remove"])
  ensure
    source.try(&.close)
    metadata.try(&.close)
    listener.try(&.close)
    auth_listener.try(&.close)
    server.try(&.stop)
  end

  it "adds, touches, and removes listed streams from YP directories" do
    yp_listener = TCPServer.new("127.0.0.1", 0)
    yp_port = yp_listener.local_address.as(Socket::IPAddress).port
    yp_requests = Channel(HTTP::Params).new(10)
    spawn do
      while socket = yp_listener.accept?
        head = read_head(socket)
        content_length = head.each_line.find(&.downcase.starts_with?("content-length:"))
          .try(&.partition(':')[2].strip.to_i) || 0
        body = Bytes.new(content_length)
        socket.read_fully(body)
        params = HTTP::Params.parse(String.new(body))
        yp_requests.send(params)
        extra = params["action"] == "add" ? "SID: spec-sid\r\nTouchFreq: 1\r\n" : ""
        socket.print "HTTP/1.0 200 OK\r\nContent-Length: 0\r\nYPResponse: 1\r\n#{extra}\r\n"
        socket.close
      end
    end

    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "secret"
    config.admin_password = "admin"
    config.max_connections_per_ip = 10
    config.public_url = "http://radio.example:8000"
    config.admin_email = "admin@example.com"
    config.plugins = {"yp" => YAML.parse("{urls: [http://127.0.0.1:#{yp_port}/yp], touch_interval: 1}")}
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    Fiber.yield

    source = TCPSocket.new("127.0.0.1", port)
    source.print "PUT /listed HTTP/1.1\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\nIce-Public: 1\r\nIce-Name: Listed Radio\r\nIce-Genre: Jazz\r\nIce-Bitrate: 192\r\nExpect: 100-continue\r\n\r\n"
    read_head(source).should start_with("HTTP/1.1 100")

    add = receive(yp_requests)
    add["action"].should eq("add")
    add["sn"].should eq("Listed Radio")
    add["listenurl"].should eq("http://radio.example:8000/listed")
    add["b"].should eq("192")

    touch = receive(yp_requests, 2.seconds)
    touch["action"].should eq("touch")
    touch["sid"].should eq("spec-sid")

    unlist_body = {listed: false}.to_json
    unlist = TCPSocket.new("127.0.0.1", port)
    unlist.print "PATCH /api/v1/stations/listed HTTP/1.1\r\nAuthorization: Basic YWRtaW46YWRtaW4=\r\nContent-Type: application/json\r\nContent-Length: #{unlist_body.bytesize}\r\n\r\n#{unlist_body}"
    read_head(unlist).should start_with("HTTP/1.0 200")
    receive(yp_requests, 2.seconds)["action"].should eq("remove")
    unlist.close

    relist_body = {listed: true}.to_json
    relist = TCPSocket.new("127.0.0.1", port)
    relist.print "PATCH /api/v1/stations/listed HTTP/1.1\r\nAuthorization: Basic YWRtaW46YWRtaW4=\r\nContent-Type: application/json\r\nContent-Length: #{relist_body.bytesize}\r\n\r\n#{relist_body}"
    read_head(relist).should start_with("HTTP/1.0 200")
    receive(yp_requests, 2.seconds)["action"].should eq("add")
    relist.close

    source.close
    remove = receive(yp_requests)
    remove["action"].should eq("remove")
    remove["sid"].should eq("spec-sid")
  ensure
    source.try(&.close)
    unlist.try(&.close)
    relist.try(&.close)
    yp_listener.try(&.close)
    server.try(&.stop)
  end
end
