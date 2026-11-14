require "../spec_helper"

private ADMIN = "Basic #{Base64.strict_encode("admin:admin")}"
private PNG   = Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4]

private def basic(user : String, password : String) : String
  "Basic #{Base64.strict_encode("#{user}:#{password}")}"
end

private def plugin_config(plugins = "{}") : Config
  config = Config.new
  config.host = "127.0.0.1"
  config.source_password = "secret"
  config.admin_password = "admin"
  config.max_connections_per_ip = 50
  config.plugins = Hash(String, YAML::Any).from_yaml(plugins)
  config
end

private def start_plugin_server(config : Config) : Tuple(IcecastServer, Int32)
  listener = TCPServer.new("127.0.0.1", 0)
  port = listener.local_address.as(Socket::IPAddress).port
  server = IcecastServer.new(config)
  spawn server.serve(listener)
  Fiber.yield
  {server, port}
end

# Sends a request and returns the response head and body.
private def http(port : Int32, request_line : String, headers = "", body = Bytes.empty) : Tuple(String, Bytes)
  socket = TCPSocket.new("127.0.0.1", port)
  socket.read_timeout = 2.seconds
  socket.print "#{request_line} HTTP/1.0\r\n#{headers}Content-Length: #{body.size}\r\n\r\n"
  socket.write(body)
  socket.flush
  head = read_head(socket)
  # The server answers errors without reading the body, so the connection may be reset after the head.
  body = socket.getb_to_end rescue Bytes.empty
  {head, body}
ensure
  socket.try(&.close)
end

private def open_source(port : Int32, mount : String) : TCPSocket
  source = TCPSocket.new("127.0.0.1", port)
  source.print "PUT #{mount} HTTP/1.1\r\nAuthorization: #{basic("source", "secret")}\r\nContent-Type: audio/mpeg\r\nExpect: 100-continue\r\n\r\n"
  read_head(source).should start_with("HTTP/1.1 100")
  source.write(mp3_frame)
  source.flush
  source
end

private def temp_dir(name : String) : String
  dir = File.join(Dir.tempdir, "lurcast-#{name}-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  dir
end

private def artwork_fragment(data : Bytes) : Bytes
  payload = Bytes.new(6 + data.size, 0_u8)
  payload[1] = 1_u8
  payload[3] = 1_u8
  payload[5] = 1_u8
  data.copy_to(payload + 6)
  payload
end

describe Lurcast::Plugins do
  it "rejects settings for plugins that do not exist" do
    expect_raises(ArgumentError, "unknown plugins: nope") { plugin_config("nope: {}").validate! }
  end

  it "turns cover art on by default and lets the configuration turn it off" do
    Lurcast::Plugins.build(plugin_config).map(&.name).should contain("cover_art")
    Lurcast::Plugins.build(plugin_config("cover_art: {enabled: false}")).map(&.name).should_not contain("cover_art")
  end
end

describe Lurcast::Plugins::CoverArt do
  it "takes uploaded artwork, serves it with an ETag, and lists it in the status JSON" do
    dir = temp_dir("art")
    config = plugin_config
    config.data_dir = dir
    server, port = start_plugin_server(config)
    source = open_source(port, "/live")

    head, _ = http(port, "POST /admin/artwork?mount=/live&type=station", "Authorization: #{ADMIN}\r\nContent-Type: text/plain\r\n", "hi".to_slice)
    head.should start_with("HTTP/1.0 415")
    head, _ = http(port, "POST /admin/artwork?mount=/live&type=station", "Content-Type: image/png\r\n", PNG)
    head.should start_with("HTTP/1.0 401")
    head, _ = http(port, "POST /admin/artwork?mount=/live&type=station", "Authorization: #{ADMIN}\r\nContent-Type: image/png\r\n", PNG)
    head.should start_with("HTTP/1.0 200")

    head, body = http(port, "GET /_lurcast/art/live")
    head.should start_with("HTTP/1.0 200")
    head.should contain("Content-Type: image/png")
    body.should eq(PNG)
    etag = head.lines.find!(&.starts_with?("ETag:")).partition(": ")[2]
    http(port, "GET /_lurcast/art/live", "If-None-Match: #{etag}\r\n")[0].should start_with("HTTP/1.0 304")
    http(port, "GET /_lurcast/art/live?type=playing")[0].should start_with("HTTP/1.0 404")

    _, status = http(port, "GET /status-json.xsl")
    JSON.parse(String.new(status))["icestats"]["source"][0]["artwork"].should eq("/_lurcast/art/live")
    _, stations = http(port, "GET /api/v1/stations")
    JSON.parse(String.new(stations))["stations"][0]["now_playing"]["artwork_url"].as_s.should end_with("/_lurcast/art/live")

    # Station logos survive a restart.
    server.stop
    source.close
    server, port = start_plugin_server(config)
    source = open_source(port, "/live")
    http(port, "GET /_lurcast/art/live")[1].should eq(PNG)

    head, _ = http(port, "POST /admin/artwork/remove?mount=/live&type=station", "Authorization: #{ADMIN}\r\n")
    head.should start_with("HTTP/1.0 200")
    http(port, "GET /_lurcast/art/live")[0].should start_with("HTTP/1.0 404")
    Dir.children(File.join(dir, "artwork")).should be_empty
  ensure
    source.try(&.close)
    server.try(&.stop)
    dir.try { |tmp| FileUtils.rm_rf(tmp) }
  end

  it "takes artwork from a SHOUTcast 2 source and serves it on the SHOUTcast paths" do
    config = plugin_config
    config.shoutcast_mounts = {1 => "/shout"}
    http_listener = TCPServer.new("127.0.0.1", 0)
    shout_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    spawn server.serve_shoutcast(shout_listener)
    Fiber.yield

    source = TCPSocket.new("127.0.0.1", shout_listener.local_address.as(Socket::IPAddress).port)
    source.read_timeout = 2.seconds
    source.write(uvox_frame(0x1001_u16, "2.1:1:source:secret\0".to_slice))
    read_uvox(source)[1].should eq("ACK:2.1:Allow\0".to_slice)
    {0x1040_u16 => "audio/mpeg\0", 0x1002_u16 => "128:128\0", 0x1003_u16 => "64:32\0", 0x1008_u16 => "16377:4096\0"}.each do |type, payload|
      source.write(uvox_frame(type, payload.to_slice))
      String.new(read_uvox(source)[1]).should start_with("ACK")
    end
    source.write(uvox_frame(0x1004_u16))
    read_uvox(source)

    jpeg = Bytes[0xff, 0xd8, 0xff, 0xe0, 9, 9]
    source.write(uvox_frame(0x4101_u16, artwork_fragment(PNG)))
    source.write(uvox_frame(0x4000_u16, artwork_fragment(jpeg)))
    wait_until { http(port, "GET /playingart?sid=1")[0].starts_with?("HTTP/1.0 200") }
    head, body = http(port, "GET /playingart?sid=1")
    head.should contain("Content-Type: image/png")
    body.should eq(PNG)
    wait_until { http(port, "GET /streamart?sid=1")[1] == jpeg }
    http(port, "GET /_lurcast/art/shout")[1].should eq(PNG)

    # An empty image removes the cover; the station logo is served instead.
    source.write(uvox_frame(0x4101_u16, artwork_fragment(Bytes.empty)))
    wait_until { http(port, "GET /_lurcast/art/shout")[1] == jpeg }
  ensure
    source.try(&.close)
    server.try(&.stop)
  end

  it "only lets a login limited to some mounts change their artwork" do
    server, port = start_plugin_server(plugin_config)
    server.add_extension(OwnMount.new)
    head, _ = http(port, "POST /admin/artwork?mount=/other", "Authorization: #{basic("owner", "pw")}\r\nContent-Type: image/png\r\n")
    head.should start_with("HTTP/1.0 404")
    head, _ = http(port, "POST /admin/artwork?mount=/mine", "Authorization: #{basic("owner", "pw")}\r\nContent-Type: image/png\r\n", PNG)
    head.should start_with("HTTP/1.0 200")
  ensure
    server.try(&.stop)
  end
end

private class OwnMount < Lurcast::Extension
  def admin_login(user : String, password : String) : Array(String)?
    ["/mine"] if user == "owner" && password == "pw"
  end
end

describe Lurcast::Plugins::Htpasswd do
  it "checks bcrypt, Apache MD5, SHA-1, and Icecast MD5 hashes" do
    htpasswd = Lurcast::Plugins::Htpasswd
    htpasswd.apr1("secret123", "abcdefgh").should eq("$apr1$abcdefgh$aQ26yFH6V5G5PJBY/utXg/")
    htpasswd.matches?("$apr1$abcdefgh$aQ26yFH6V5G5PJBY/utXg/", "secret123").should be_true
    htpasswd.matches?("$apr1$abcdefgh$aQ26yFH6V5G5PJBY/utXg/", "secret124").should be_false
    htpasswd.matches?("{SHA}W6ph5Mm5Pz8GgiULbPgzG37mj9g=", "password").should be_true
    htpasswd.matches?("5f4dcc3b5aa765d61d8327deb882cf99", "password").should be_true
    bcrypt = Crypto::Bcrypt::Password.create("pw", cost: 4).to_s
    htpasswd.matches?(bcrypt.sub("$2a$", "$2y$"), "pw").should be_true
    htpasswd.matches?("garbage", "pw").should be_false
  end

  it "adds, changes, and removes users, and rereads the file when it changes" do
    dir = temp_dir("htpasswd")
    path = File.join(dir, "listeners.htpasswd")
    file = Lurcast::Plugins::Htpasswd.new(path)
    file.users.should be_empty
    file.set("anna", "one")
    file.set("bo", "two")
    file.verify?("anna", "one").should be_true
    file.set("anna", "uno")
    file.verify?("anna", "one").should be_false
    file.delete("bo").should be_true
    file.delete("bo").should be_false
    File.read(path).lines.map(&.partition(':')[0]).should eq(["anna"])
    File.info(path).permissions.value.should eq(0o600)

    File.write(path, "# comment\ncarl:5f4dcc3b5aa765d61d8327deb882cf99\n")
    File.touch(path, Time.utc + 5.seconds)
    reread = Lurcast::Plugins::Htpasswd.new(path)
    reread.users.should eq(["carl"])
    expect_raises(ArgumentError) { reread.set("a:b", "pw") }
  ensure
    dir.try { |tmp| FileUtils.rm_rf(tmp) }
  end
end

describe Lurcast::Plugins::ListenerLogins do
  it "validates its settings" do
    expect_raises(ArgumentError, /at least one mount/) { plugin_config("listener_logins: {}").validate! }
    expect_raises(ArgumentError, /must start with/) { plugin_config("listener_logins: {mounts: {live: /tmp/x}}").validate! }
    plugin_config("listener_logins: {mounts: {/live: /tmp/x, \"*\": /tmp/y}}").validate!
  end

  it "asks listeners of a protected mount to sign in, and lets admins manage the logins" do
    dir = temp_dir("logins")
    config = plugin_config("listener_logins: {realm: Members, mounts: {/private: #{dir}/private.htpasswd}}")
    server, port = start_plugin_server(config)
    source = open_source(port, "/private")
    open_source(port, "/public").close

    head, _ = http(port, "POST /admin/listener-logins?mount=/private&user=anna&password=s3cret", "Authorization: #{ADMIN}\r\n")
    head.should start_with("HTTP/1.0 200")
    _, body = http(port, "GET /admin/api/listener-logins?mount=/private", "Authorization: #{ADMIN}\r\n")
    JSON.parse(String.new(body))["users"].should eq(["anna"])
    http(port, "GET /admin/api/listener-logins?mount=/public", "Authorization: #{ADMIN}\r\n")[0].should start_with("HTTP/1.0 404")

    head, _ = http(port, "GET /private")
    head.should start_with("HTTP/1.0 401")
    head.should contain(%(WWW-Authenticate: Basic realm="Members"))
    http(port, "GET /private", "Authorization: #{basic("anna", "wrong")}\r\n")[0].should start_with("HTTP/1.0 401")

    listener = TCPSocket.new("127.0.0.1", port)
    listener.read_timeout = 2.seconds
    listener.print "GET /private HTTP/1.0\r\nAuthorization: #{basic("anna", "s3cret")}\r\n\r\n"
    read_head(listener).should start_with("HTTP/1.0 200")
    listener.close

    head, _ = http(port, "POST /admin/listener-logins/remove?mount=/private&user=anna", "Authorization: #{ADMIN}\r\n")
    head.should start_with("HTTP/1.0 200")
    http(port, "GET /private", "Authorization: #{basic("anna", "s3cret")}\r\n")[0].should start_with("HTTP/1.0 401")
  ensure
    source.try(&.close)
    server.try(&.stop)
    dir.try { |tmp| FileUtils.rm_rf(tmp) }
  end
end
