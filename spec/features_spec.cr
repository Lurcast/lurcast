require "./spec_helper"
require "http/server"

private FEATURE_SOURCE_AUTH = "Basic c291cmNlOnNlY3JldA==" # source:secret
private FEATURE_ADMIN_AUTH  = "Basic YWRtaW46YWRtaW4="     # admin:admin

private def feature_config : Config
  config = Config.new
  config.host = "127.0.0.1"
  config.source_password = "secret"
  config.admin_password = "admin"
  config.max_connections_per_ip = 50
  config
end

private def start_feature_server(config : Config) : Tuple(IcecastServer, Int32)
  listener = TCPServer.new("127.0.0.1", 0)
  port = listener.local_address.as(Socket::IPAddress).port
  server = IcecastServer.new(config)
  spawn server.serve(listener)
  Fiber.yield
  {server, port}
end

private def feature_request(port : Int32, request_line : String, headers = "") : Tuple(String, Bytes)
  socket = TCPSocket.new("127.0.0.1", port)
  socket.read_timeout = 2.seconds
  socket.print "#{request_line} HTTP/1.0\r\n#{headers}\r\n"
  head = read_head(socket)
  body = IO::Memory.new
  IO.copy(socket, body)
  {head, body.to_slice}
ensure
  socket.try(&.close)
end

private def open_feature_source(port : Int32, mount : String) : TCPSocket
  source = TCPSocket.new("127.0.0.1", port)
  source.print "PUT #{mount} HTTP/1.1\r\nAuthorization: #{FEATURE_SOURCE_AUTH}\r\nContent-Type: audio/mpeg\r\nIce-Name: Feature FM\r\nExpect: 100-continue\r\n\r\n"
  read_head(source).should start_with("HTTP/1.1 100")
  source
end

private def send_frames(source : IO, count : Int32)
  count.times { source.write(mp3_frame) }
  source.flush
end

private def temp_dir(name : String) : String
  path = File.join(Dir.tempdir, "lurcast-#{name}-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(path)
  path
end

describe "Access log" do
  it "formats combined log lines and masks passwords" do
    entry = AccessLog::Entry.new(address: "203.0.113.7", user: "admin", started_at: Time.utc(2026, 11, 13, 22, 1, 14),
      method: "GET", target: "/admin.cgi?mode=viewxml&pass=s3cret&sid=1", version: "HTTP/1.1", status: 200, bytes: 512_i64,
      referer: nil, user_agent: %(Player "1"), duration: 125.seconds)
    AccessLog.format(entry).should eq(%(203.0.113.7 - admin [13/Nov/2026:22:01:14 +0000] "GET /admin.cgi?mode=viewxml&pass=*****&sid=1 HTTP/1.1" 200 512 "-" "Player \\"1\\"" 125))
  end

  it "logs requests and finished listeners to the file" do
    dir = temp_dir("access")
    config = feature_config
    config.access_log = File.join(dir, "access.log")
    server, port = start_feature_server(config)
    source = open_feature_source(port, "/live")
    send_frames(source, 3)

    feature_request(port, "GET /status-json.xsl", "User-Agent: SpecBrowser\r\n")[0].should start_with("HTTP/1.0 200")
    listener = TCPSocket.new("127.0.0.1", port)
    listener.print "GET /live HTTP/1.0\r\nUser-Agent: SpecPlayer\r\n\r\n"
    read_head(listener)
    send_frames(source, 2)
    sleep 50.milliseconds
    listener.close

    log = File.join(dir, "access.log")
    wait_until(3.seconds) { File.exists?(log) && File.read(log).includes?("GET /live ") }
    lines = File.read(log).lines
    (lines.find(&.includes?("GET /status-json.xsl")) || raise "no status line").should match(/^127\.0\.0\.1 - - \[.+\] "GET \/status-json\.xsl HTTP\/1\.0" 200 \d+ "-" "SpecBrowser" 0$/)
    (lines.find(&.includes?("GET /live ")) || raise "no listener line").should match(/"GET \/live HTTP\/1\.0" 200 [1-9]\d* "-" "SpecPlayer"/)
  ensure
    source.try(&.close)
    server.try(&.stop)
  end
end

describe "Webhooks" do
  it "posts signed events with retries" do
    received = Channel(Tuple(String, String, String)).new(16)
    attempts = 0
    hook = HTTP::Server.new do |context|
      attempts += 1
      body = context.request.body.try(&.gets_to_end) || ""
      if attempts == 1
        context.response.status_code = 503
      else
        received.send({context.request.headers["X-Lurcast-Event"], context.request.headers["X-Lurcast-Signature"]? || "", body})
        context.response.status_code = 204
      end
    end
    address = hook.bind_tcp("127.0.0.1", 0)
    spawn hook.listen

    webhooks = Webhooks.new([WebhookConfig.new("http://127.0.0.1:#{address.port}/hook", secret: "shh")], "https://radio.example", "Lurcast/test", 2.seconds)
    webhooks.emit(Webhooks::SongChanged.new("/live", "A - B", 3))
    event, signature, body = receive(received, 5.seconds)

    event.should eq("song.changed")
    signature.should eq("sha256=#{OpenSSL::HMAC.hexdigest(:sha256, "shh", body)}")
    json = JSON.parse(body)
    json["data"]["song"].as_s.should eq("A - B")
    json["server"].as_s.should eq("https://radio.example")
    attempts.should eq(2)
  ensure
    webhooks.try(&.close)
    hook.try(&.close)
  end

  it "lists every event record in the configuration's event names" do
    events = [Webhooks::SourceConnected::EVENT, Webhooks::SourceDisconnected::EVENT, Webhooks::SongChanged::EVENT,
              Webhooks::ListenerConnected::EVENT, Webhooks::ListenerDisconnected::EVENT, Webhooks::RecordingFinished::EVENT,
              Webhooks::ConfigReloaded::EVENT]
    events.sort.should eq(WebhookConfig::EVENTS.sort)
  end

  it "sends only subscribed events and rejects unknown names" do
    WebhookConfig.new("https://a.example").wants?("listener.connected").should be_false
    WebhookConfig.new("https://a.example").wants?("song.changed").should be_true
    WebhookConfig.new("https://a.example", ["listener.connected"]).wants?("song.changed").should be_false

    config = feature_config
    config.webhooks = [WebhookConfig.new("https://a.example", ["song.played"])]
    expect_raises(ArgumentError, /unknown webhook events: song.played/) { config.validate! }
  end
end

describe "Recording" do
  it "records a mount on demand and on connect, and serves the files to the admin only" do
    dir = temp_dir("rec")
    config = feature_config
    config.recordings_dir = dir
    config.mounts = {"/auto" => MountConfig.new(record: true)}
    server, port = start_feature_server(config)
    auto = open_feature_source(port, "/auto")
    send_frames(auto, 4)
    live = open_feature_source(port, "/live")
    send_frames(live, 2)

    admin = "Authorization: #{FEATURE_ADMIN_AUTH}\r\n"
    feature_request(port, "POST /admin/record?mount=/live&action=start", admin)[0].should start_with("HTTP/1.0 200")
    send_frames(live, 5)
    sleep 1.1.seconds
    send_frames(live, 1)
    wait_until(3.seconds) { Dir.glob(File.join(dir, "live", "*.mp3")).any? { |file| File.size(file) >= 5 * mp3_frame.size } }
    feature_request(port, "POST /admin/record?mount=/live&action=stop", admin)[1].should eq("Recording stopped".to_slice)

    files = Dir.glob(File.join(dir, "live", "*.mp3"))
    files.size.should eq(1)
    (File.size(files.first) % mp3_frame.size).should eq(0)

    head, body = feature_request(port, "GET /admin/api/recordings?mount=/live", admin)
    head.should start_with("HTTP/1.0 200")
    name = JSON.parse(String.new(body))["files"][0]["name"].as_s
    feature_request(port, "GET /admin/recordings/live/#{name}")[0].should start_with("HTTP/1.0 401")
    download_head, download = feature_request(port, "GET /admin/recordings/live/#{name}", admin)
    download_head.should contain("Content-Disposition: attachment")
    download.size.should eq(File.size(files.first))
    feature_request(port, "GET /admin/recordings/live/..%2F..%2Fetc", admin)[0].should start_with("HTTP/1.0 404")
    feature_request(port, "GET /admin/recordings/../live/#{name}", admin)[0].should start_with("HTTP/1.0 404")

    auto.close
    wait_until { server.recording_for("/auto").nil? }
    Dir.glob(File.join(dir, "auto", "*.mp3")).size.should eq(1)
  ensure
    auto.try(&.close)
    live.try(&.close)
    server.try(&.stop)
  end

  it "names directories safely" do
    Recording.slug("/live").should eq("live")
    Recording.slug("/a/b c").should eq("a_bc")
    Recording.slug("/..").should eq("_")
    Recording.extension_for("audio/aacp").should eq("aac")
  end
end

describe "HLS" do
  it "serves a playlist and segments for MP3 mounts" do
    config = feature_config
    config.hls = true
    config.hls_segment_seconds = 1
    server, port = start_feature_server(config)
    source = open_feature_source(port, "/live")
    send_frames(source, 120) # about 3 seconds of 44.1 kHz MP3

    playlist = ""
    wait_until(3.seconds) do
      head, body = feature_request(port, "GET /live.m3u8")
      playlist = String.new(body)
      head.starts_with?("HTTP/1.0 200")
    end
    playlist.should start_with("#EXTM3U")
    uri = playlist.lines.find(&.starts_with?("/_lurcast/hls/live/")) || raise "no segment in playlist"
    head, segment = feature_request(port, "GET #{uri}")
    head.should contain("Content-Type: audio/mpeg")
    String.new(segment[0, 3]).should eq("ID3")

    feature_request(port, "GET /missing.m3u8")[0].should start_with("HTTP/1.0 404")
    feature_request(port, "GET /_lurcast/hls/live/1.mp3")[0].should start_with("HTTP/1.0 404")
  ensure
    source.try(&.close)
    server.try(&.stop)
  end
end

describe "Configuration reload" do
  it "applies a valid file and keeps the running configuration when the file is invalid" do
    dir = temp_dir("reload")
    path = File.join(dir, "config.yml")
    File.write(path, "host: 127.0.0.1\nsource_password: secret\nadmin_password: admin\nmax_listeners: 10\n")
    config = Config.load(path)
    server, port = start_feature_server(config)
    server.config_path = path

    File.write(path, "host: 127.0.0.1\nport: 9999\nsource_password: secret\nadmin_password: admin\nmax_listeners: 25\nmounts:\n  /new:\n    hidden: true\n")
    head, body = feature_request(port, "POST /admin/reload", "Authorization: #{FEATURE_ADMIN_AUTH}\r\n")
    head.should start_with("HTTP/1.0 200")
    JSON.parse(String.new(body))["restart_required"].as_a.map(&.as_s).should eq(["port"])
    config.max_listeners.should eq(25)
    config.hidden?("/new").should be_true
    config.port.should_not eq(9999)

    File.write(path, "max_listeners: [broken\n")
    result = server.reload_config
    result.ok.should be_false
    config.max_listeners.should eq(25)
  ensure
    server.try(&.stop)
  end
end

private class CountryExtension < Lurcast::Extension
  def listener_country(address : String) : String?
    "SE"
  end

  def locations_source : String?
    "Spec countries"
  end
end

describe "Listener locations from extensions" do
  it "stores the country an extension returns and shows it to the admin" do
    server, port = start_feature_server(feature_config)
    server.add_extension(CountryExtension.new)
    source = open_feature_source(port, "/live")
    send_frames(source, 2)
    listener = TCPSocket.new("127.0.0.1", port)
    listener.print "GET /live HTTP/1.0\r\n\r\n"
    read_head(listener)

    admin = "Authorization: #{FEATURE_ADMIN_AUTH}\r\n"
    overview = JSON.parse(String.new(feature_request(port, "GET /admin/api/overview", admin)[1]))
    overview["server"]["features"]["locations"].as_s.should eq("Spec countries")
    overview["mounts"][0]["countries"].as_h.should eq({"SE" => JSON::Any.new(1_i64)})
    overview["mounts"][0]["clients"]?.should be_nil

    with_clients = JSON.parse(String.new(feature_request(port, "GET /admin/api/overview?clients=/live", admin)[1]))
    with_clients["mounts"][0]["clients"][0]["country"].as_s.should eq("SE")
  ensure
    listener.try(&.close)
    source.try(&.close)
    server.try(&.stop)
  end
end

describe TrustedProxies do
  it "takes the client address from X-Forwarded-For only behind trusted proxies" do
    proxies = TrustedProxies.new(["127.0.0.1", "10.0.0.0/8", "fd00::/8"])
    proxies.client_address("127.0.0.1", "198.51.100.4").should eq("198.51.100.4")
    proxies.client_address("127.0.0.1", "203.0.113.9, 10.1.2.3").should eq("203.0.113.9")
    proxies.client_address("127.0.0.1", "spoofed, 198.51.100.4").should eq("198.51.100.4")
    proxies.client_address("198.51.100.4", "1.2.3.4").should eq("198.51.100.4")
    proxies.client_address("fd00::1", "2001:db8::5").should eq("2001:db8::5")
    proxies.client_address("::ffff:127.0.0.1", "198.51.100.4").should eq("198.51.100.4")
    proxies.client_address("127.0.0.1", "not-an-ip").should eq("127.0.0.1")
    TrustedProxies.valid?("10.0.0.0/33").should be_false
  end
end
