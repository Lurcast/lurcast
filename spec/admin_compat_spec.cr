require "./spec_helper"

private SOURCE_AUTH = "Basic c291cmNlOnNlY3JldA==" # source:secret
private ADMIN_AUTH  = "Basic YWRtaW46YWRtaW4="     # admin:admin

private def compat_config : Config
  config = Config.new
  config.host = "127.0.0.1"
  config.source_password = "secret"
  config.admin_password = "admin"
  config.max_connections_per_ip = 50
  config
end

private def start_server(config : Config) : Tuple(IcecastServer, Int32)
  listener = TCPServer.new("127.0.0.1", 0)
  port = listener.local_address.as(Socket::IPAddress).port
  server = IcecastServer.new(config)
  spawn server.serve(listener)
  Fiber.yield
  {server, port}
end

private def http(port : Int32, request_line : String, authorization : String? = nil, extra = "") : Tuple(String, String)
  socket = TCPSocket.new("127.0.0.1", port)
  socket.read_timeout = 2.seconds
  auth = authorization ? "Authorization: #{authorization}\r\n" : ""
  socket.print "#{request_line} HTTP/1.0\r\n#{auth}#{extra}\r\n"
  head = read_head(socket)
  {head, socket.gets_to_end}
ensure
  socket.try(&.close)
end

private def open_source(port : Int32, mount : String, authorization = SOURCE_AUTH, content_type = "audio/mpeg") : TCPSocket
  source = TCPSocket.new("127.0.0.1", port)
  source.print "PUT #{mount} HTTP/1.1\r\nAuthorization: #{authorization}\r\nContent-Type: #{content_type}\r\nIce-Name: #{mount} radio\r\nIce-Genre: Jazz\r\nExpect: 100-continue\r\n\r\n"
  read_head(source).should start_with("HTTP/1.1 100")
  source
end

private def open_listener(port : Int32, mount : String, user_agent = "SpecPlayer/1.0") : TCPSocket
  listener = TCPSocket.new("127.0.0.1", port)
  listener.read_timeout = 2.seconds
  listener.print "GET #{mount} HTTP/1.0\r\nUser-Agent: #{user_agent}\r\n\r\n"
  read_head(listener).should start_with("HTTP/1.0 200")
  listener
end

private def read_bytes(socket : IO, size : Int32) : Bytes
  bytes = Bytes.new(size)
  socket.read_fully(bytes)
  bytes
end

describe "Icecast admin compatibility" do
  it "lists, moves, and kicks listeners with XML responses" do
    server, port = start_server(compat_config)
    live = open_source(port, "/live")
    backup = open_source(port, "/backup")
    listener = open_listener(port, "/live")
    wait_until { server.get_mount("/live").try(&.listener_count) == 1 }

    http(port, "GET /admin/listclients?mount=/live")[0].should start_with("HTTP/1.0 401")
    head, body = http(port, "GET /admin/listclients?mount=/live", ADMIN_AUTH)
    head.should start_with("HTTP/1.0 200")
    head.should contain("Content-Type: text/xml")
    body.should contain(%(<source mount="/live"><Listeners>1</Listeners><listener><IP>127.0.0.1</IP><UserAgent>SpecPlayer/1.0</UserAgent>))
    id = body.match!(/<ID>(\d+)<\/ID>/)[1].to_i64

    http(port, "GET /admin/moveclients?mount=/live&destination=/missing", ADMIN_AUTH)[0].should start_with("HTTP/1.0 400")
    head, body = http(port, "GET /admin/moveclients?mount=/live&destination=/backup", ADMIN_AUTH)
    head.should start_with("HTTP/1.0 200")
    body.should contain("<return>1</return>")
    server.get_mount("/backup").try(&.listener_count).should eq(1)
    server.get_mount("/live").try(&.listener_count).should eq(0)

    sleep 600.milliseconds
    audio = mp3_frame(3_u8) + mp3_frame(3_u8)
    backup.write(audio)
    read_bytes(listener, audio.size).should eq(audio)
    live.write(mp3_frame(4_u8))

    http(port, "GET /admin/killclient?mount=/backup&id=999999", ADMIN_AUTH)[0].should start_with("HTTP/1.0 404")
    head, body = http(port, "POST /admin/killclient?mount=/backup&id=#{id}", ADMIN_AUTH)
    head.should start_with("HTTP/1.0 200")
    body.should contain("Client #{id} removed")
    wait_until { server.get_mount("/backup").try(&.listener_count) == 0 }
    listener.gets_to_end.should be_empty
  ensure
    live.try(&.close)
    backup.try(&.close)
    listener.try(&.close)
    server.try(&.stop)
  end

  it "renders XML stats and mount lists, including hidden mounts only for admins" do
    config = compat_config
    config.hostname = "radio.example"
    config.mounts = {"/secret" => MountConfig.new(hidden: true, max_listeners: 7)}
    server, port = start_server(config)
    live = open_source(port, "/live")
    secret = open_source(port, "/secret")
    wait_until { server.streams.size == 2 }
    server.get_mount("/live").try(&.update_metadata("Artist & <Song>"))

    head, body = http(port, "GET /admin/stats", ADMIN_AUTH)
    head.should start_with("HTTP/1.0 200")
    body.should start_with(%(<?xml version="1.0" encoding="UTF-8"?>\n<icestats>))
    body.should contain("<host>radio.example</host>")
    body.should contain("<sources>2</sources>")
    body.should contain(%(<source mount="/live">))
    body.should contain("<title>Artist &amp; &lt;Song&gt;</title>")
    body.should contain("<max_listeners>unlimited</max_listeners>")
    body.should contain(%(<source mount="/secret">))
    body.should contain("<max_listeners>7</max_listeners>")

    head, body = http(port, "GET /admin/listmounts", ADMIN_AUTH)
    head.should start_with("HTTP/1.0 200")
    body.should contain(%(<source mount="/live"><listeners>0</listeners><Connected>))
    body.should contain("<content-type>audio/mpeg</content-type>")

    public_status = JSON.parse(http(port, "GET /status-json.xsl")[1])["icestats"]
    public_status["source"].as_a.map(&.["mount"].as_s).should eq(["/live"])
    JSON.parse(http(port, "GET /api/v1/stations")[1])["stations"].as_a.map(&.["mount"].as_s).should eq(["/live"])
    http(port, "GET /")[1].should_not contain("/secret")
    JSON.parse(http(port, "GET /admin/stats.json", ADMIN_AUTH)[1])["icestats"]["sources"].as_i.should eq(2)

    http(port, "HEAD /admin/moveclients?mount=/live&destination=/secret", ADMIN_AUTH)[0].should start_with("HTTP/1.0 405")
  ensure
    live.try(&.close)
    secret.try(&.close)
    server.try(&.stop)
  end

  it "requires per-mount source credentials when a mount defines them" do
    config = compat_config
    config.mounts = {"/dj" => MountConfig.new(username: "dj", password: "turntable")}
    server, port = start_server(config)

    rejected = TCPSocket.new("127.0.0.1", port)
    rejected.print "PUT /dj HTTP/1.1\r\nAuthorization: #{SOURCE_AUTH}\r\nContent-Type: audio/mpeg\r\n\r\n"
    read_head(rejected).should start_with("HTTP/1.0 401")
    rejected.close

    dj_auth = "Basic #{Base64.strict_encode("dj:turntable")}"
    dj = open_source(port, "/dj", dj_auth)
    wait_until { server.get_mount("/dj").try(&.has_source?) || false }
    http(port, "GET /admin/metadata?mount=/dj&song=Live+Set", dj_auth)[0].should start_with("HTTP/1.0 200")
    server.get_mount("/dj").try(&.current_song).should eq("Live Set")

    other = open_source(port, "/other")
    wait_until { server.get_mount("/other").try(&.has_source?) || false }
  ensure
    rejected.try(&.close)
    dj.try(&.close)
    other.try(&.close)
    server.try(&.stop)
  end

  it "sends a mount's intro file before the live burst" do
    webroot = File.tempname("lurcast-intro", nil)
    Dir.mkdir_p(webroot)
    intro = mp3_frame(9_u8)
    File.write(File.join(webroot, "intro.mp3"), intro)
    config = compat_config
    config.webroot = webroot
    config.mounts = {"/live" => MountConfig.new(intro: "intro.mp3")}
    server, port = start_server(config)
    live = open_source(port, "/live")
    live.write(mp3_frame(1_u8) + mp3_frame(1_u8))
    wait_until { !server.get_mount("/live").try(&.mp3_info).nil? }
    burst = (server.get_mount("/live") || raise "expected /live").initial_burst
    burst.should_not be_empty

    listener = open_listener(port, "/live")
    read_bytes(listener, intro.size).should eq(intro)
    read_bytes(listener, burst.size).should eq(burst)
  ensure
    live.try(&.close)
    listener.try(&.close)
    server.try(&.stop)
    FileUtils.rm_rf(webroot) if webroot
  end
end

describe "SHOUTcast DNAS compatibility" do
  it "serves 7.html, stats, current song, and song history" do
    config = compat_config
    config.shoutcast_mount = "/live"
    server, port = start_server(config)
    live = open_source(port, "/live")
    listener = open_listener(port, "/live")
    wait_until { server.get_mount("/live").try(&.listener_count) == 1 }
    mount = server.get_mount("/live") || raise "expected /live"
    mount.update_metadata("First Song")
    mount.update_metadata("Second, Song")

    head, body = http(port, "GET /7.html")
    head.should contain("Content-Type: text/html")
    body.should eq("<html><body>1,1,1,1000,1,128,Second, Song</body></html>")

    stats = JSON.parse(http(port, "GET /stats?sid=1&json=1")[1])
    stats["currentlisteners"].as_i.should eq(1)
    stats["uniquelisteners"].as_i.should eq(1)
    stats["streamstatus"].as_i.should eq(1)
    stats["servertitle"].as_s.should eq("/live radio")
    stats["songtitle"].as_s.should eq("Second, Song")
    stats["streampath"].as_s.should eq("/live")
    stats["content"].as_s.should eq("audio/mpeg")

    head, body = http(port, "GET /stats?sid=1")
    head.should contain("Content-Type: text/xml")
    body.should contain("<SHOUTCASTSERVER><CURRENTLISTENERS>1</CURRENTLISTENERS>")
    body.should contain("<SONGTITLE>Second, Song</SONGTITLE>")

    http(port, "GET /currentsong?sid=1")[1].should eq("Second, Song")
    http(port, "GET /stats?sid=9")[0].should start_with("HTTP/1.0 404")

    played = JSON.parse(http(port, "GET /played?sid=1&type=json")[1]).as_a
    played.map(&.["title"].as_s).should eq(["Second, Song", "First Song"])
    http(port, "GET /played?sid=1")[1].should contain("<SONGHISTORY><SONG><PLAYEDAT>")
    http(port, "GET /played.html?sid=1")[1].should contain("<td>First Song</td>")

    statistics = JSON.parse(http(port, "GET /statistics?json=1")[1])
    statistics["totalstreams"].as_i.should eq(1)
    statistics["activestreams"].as_i.should eq(1)
    statistics["streams"].as_a.first["id"].as_i.should eq(1)
    http(port, "GET /statistics")[1].should contain(%(<STREAMSTATS><TOTALSTREAMS>1</TOTALSTREAMS>))
  ensure
    live.try(&.close)
    listener.try(&.close)
    server.try(&.stop)
  end

  it "supports admin.cgi viewxml, kickdst, and kicksrc for admins" do
    config = compat_config
    config.shoutcast_mount = "/live"
    server, port = start_server(config)
    live = open_source(port, "/live")
    listener = open_listener(port, "/live", "SpecAmp/5.9")
    wait_until { server.get_mount("/live").try(&.listener_count) == 1 }

    http(port, "GET /admin.cgi?sid=1&mode=viewxml&pass=secret")[0].should start_with("HTTP/1.0 401")
    body = http(port, "GET /admin.cgi?sid=1&mode=viewxml&pass=admin")[1]
    body.should contain("<LISTENERS><LISTENER><HOSTNAME>127.0.0.1</HOSTNAME><USERAGENT>SpecAmp/5.9</USERAGENT>")
    uid = body.match!(/<UID>(\d+)<\/UID>/)[1]
    JSON.parse(http(port, "GET /admin.cgi?sid=1&mode=viewjson&pass=admin")[1])["listeners"].as_a.size.should eq(1)

    http(port, "GET /admin.cgi?sid=1&mode=updinfo&pass=secret&song=Hello")[0].should start_with("HTTP/1.0 200")
    server.get_mount("/live").try(&.current_song).should eq("Hello")

    http(port, "GET /admin.cgi?sid=1&mode=kickdst&kickdst=#{uid}&pass=admin")[0].should start_with("HTTP/1.0 200")
    wait_until { server.get_mount("/live").try(&.listener_count) == 0 }

    http(port, "GET /admin.cgi?sid=1&mode=kicksrc&pass=admin")[0].should start_with("HTTP/1.0 200")
    wait_until { server.get_mount("/live").nil? }
  ensure
    live.try(&.close)
    listener.try(&.close)
    server.try(&.stop)
  end
end

describe MountPoint do
  it "keeps a bounded, newest-first song history" do
    mount = MountPoint.new("/live", song_history_size: 2)
    mount.update_metadata("One")
    mount.update_metadata("One")
    mount.update_metadata("")
    mount.update_metadata("Two")
    mount.update_metadata("Three")

    mount.song_history.map(&.title).should eq(["Three", "Two"])
  end
end

describe Config do
  it "validates per-mount source credentials and intro files" do
    expect_raises(ArgumentError, "username requires a password") do
      Config.from_yaml("mounts:\n  /live:\n    username: dj\n").validate!
    end
    expect_raises(ArgumentError, "intro requires webroot") do
      Config.from_yaml("mounts:\n  /live:\n    intro: intro.mp3\n").validate!
    end

    config = Config.from_yaml("mounts:\n  /live:\n    username: dj\n    password: pw\n    hidden: true\n")
    config.source_credentials_for("/live").should eq({"dj", "pw"})
    config.source_credentials_for("/other").should eq({"source", "hackme"})
    config.hidden?("/live").should be_true
  end
end
