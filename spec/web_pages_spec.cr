require "./spec_helper"
require "compress/gzip"

private PAGES_SOURCE_AUTH = "Basic c291cmNlOnNlY3JldA==" # source:secret
private PAGES_ADMIN_AUTH  = "Basic YWRtaW46YWRtaW4="     # admin:admin

private def pages_config : Config
  config = Config.new
  config.host = "127.0.0.1"
  config.source_password = "secret"
  config.admin_password = "admin"
  config.max_connections_per_ip = 50
  config
end

private def start_pages_server(config = pages_config) : Tuple(IcecastServer, Int32)
  listener = TCPServer.new("127.0.0.1", 0)
  port = listener.local_address.as(Socket::IPAddress).port
  server = IcecastServer.new(config)
  spawn server.serve(listener)
  Fiber.yield
  {server, port}
end

private def page(port : Int32, request_line : String, headers = "") : Tuple(String, String)
  socket = TCPSocket.new("127.0.0.1", port)
  socket.read_timeout = 2.seconds
  socket.print "#{request_line} HTTP/1.0\r\n#{headers}\r\n"
  head = read_head(socket)
  {head, socket.gets_to_end}
ensure
  socket.try(&.close)
end

private def night_mount(server : IcecastServer) : MountPoint
  server.get_mount("/night") || raise "/night is not live"
end

private def open_pages_source(port : Int32, mount : String) : TCPSocket
  source = TCPSocket.new("127.0.0.1", port)
  source.print "PUT #{mount} HTTP/1.1\r\nAuthorization: #{PAGES_SOURCE_AUTH}\r\nContent-Type: audio/mpeg\r\nIce-Name: Night <Owl>\r\nIce-Genre: Jazz\r\nExpect: 100-continue\r\n\r\n"
  read_head(source).should start_with("HTTP/1.1 100")
  source
end

describe "Built-in web pages" do
  it "serves the public status page at the Icecast paths with live data, escaped" do
    server, port = start_pages_server
    source = open_pages_source(port, "/night")
    night_mount(server).update_metadata(%(Artist - "Song" <i>))

    {"/", "/status.xsl", "/status.html"}.each do |path|
      head, body = page(port, "GET #{path}")
      head.should start_with("HTTP/1.0 200")
      head.should contain("Content-Type: text/html")
      head.should contain("Content-Security-Policy: default-src 'none'")
      body.should contain("Night &lt;Owl&gt;")
      body.should contain("Artist - &quot;Song&quot; &lt;i&gt;")
      body.should contain(%(href="/night.m3u"))
      body.should contain("/_lurcast/status.js?v=#{WebAssets::VERSION}")
    end
  ensure
    source.try(&.close)
    server.try(&.stop)
  end

  it "styles the SHOUTcast song history page and keeps its table cells" do
    config = pages_config
    config.shoutcast_mount = "/night"
    server, port = start_pages_server(config)
    source = open_pages_source(port, "/night")
    night_mount(server).update_metadata("First <Song>")

    head, body = page(port, "GET /played.html?sid=1")
    head.should start_with("HTTP/1.0 200")
    body.should contain("<td>First &lt;Song&gt;</td>")
    body.should contain("Song history")
  ensure
    source.try(&.close)
    server.try(&.stop)
  end

  it "serves compiled assets with long caching only for the current version" do
    server, port = start_pages_server

    head, body = page(port, "GET /_lurcast/admin.js?v=#{WebAssets::VERSION}")
    head.should start_with("HTTP/1.0 200")
    head.should contain("Content-Type: text/javascript")
    head.should contain("immutable")
    body.should contain("/admin/api/overview")

    page(port, "GET /_lurcast/style.css")[0].should contain("Cache-Control: no-cache")
    gzip_head, gzipped = page(port, "GET /_lurcast/admin.js", "Accept-Encoding: gzip, deflate\r\n")
    gzip_head.should contain("Content-Encoding: gzip")
    gzip_head.should contain("Vary: Accept-Encoding")
    Compress::Gzip::Reader.open(IO::Memory.new(gzipped), &.gets_to_end).should eq(WebAssets::FILES["admin.js"][1])
    page(port, "GET /_lurcast/style.css", %(If-None-Match: "#{WebAssets::VERSION}"\r\n))[0].should start_with("HTTP/1.0 304")
    page(port, "GET /_lurcast/missing.js")[0].should start_with("HTTP/1.0 404")
  ensure
    server.try(&.stop)
  end

  it "serves the admin shell without credentials and keeps /admin JSON for scripts" do
    server, port = start_pages_server

    head, body = page(port, "GET /admin/")
    head.should start_with("HTTP/1.0 200")
    head.should contain("X-Frame-Options: DENY")
    head.should contain("frame-ancestors 'none'")
    body.should contain("/_lurcast/admin.js?v=")

    page(port, "GET /admin", "Accept: text/html\r\n")[0].should contain("Location: /admin/")
    page(port, "GET /admin")[0].should start_with("HTTP/1.0 401")
    admin_head, admin_body = page(port, "GET /admin", "Authorization: #{PAGES_ADMIN_AUTH}\r\n")
    admin_head.should contain("application/json")
    admin_body.should contain("icestats")
  ensure
    server.try(&.stop)
  end

  it "returns the dashboard overview only to the admin, without a browser password prompt" do
    config = pages_config
    config.mounts = {"/later" => MountConfig.new(max_listeners: 5)}
    server, port = start_pages_server(config)
    source = open_pages_source(port, "/night")
    listener = TCPSocket.new("127.0.0.1", port)
    listener.print "GET /night HTTP/1.0\r\nUser-Agent: SpecPlayer/2.0\r\n\r\n"
    read_head(listener).should start_with("HTTP/1.0 200")
    wait_until { night_mount(server).listener_count == 1 }

    head, _ = page(port, "GET /admin/api/overview")
    head.should start_with("HTTP/1.0 401")
    head.should_not contain("WWW-Authenticate")

    head, body = page(port, "GET /admin/api/overview?clients=/night", "Authorization: #{PAGES_ADMIN_AUTH}\r\nOrigin: https://elsewhere.example\r\n")
    head.should start_with("HTTP/1.0 200")
    head.should_not contain("Access-Control-Allow-Origin")
    overview = JSON.parse(body)
    overview["server"]["listeners"].as_i.should eq(1)
    overview["server"]["default_passwords"].as_a.map(&.as_s).should eq(["relay_password"])
    mounts = overview["mounts"].as_a.to_h { |mount| {mount["mount"].as_s, mount} }
    mounts["/later"]["online"].as_bool.should be_false
    mounts["/later"]["max_listeners"].as_i.should eq(5)
    night = mounts["/night"]
    night["online"].as_bool.should be_true
    night["name"].as_s.should eq("Night <Owl>")
    night["protocol"].as_s.should eq("icecast")
    night["clients"][0]["user_agent"].as_s.should eq("SpecPlayer/2.0")
  ensure
    listener.try(&.close)
    source.try(&.close)
    server.try(&.stop)
  end

  it "refuses admin actions from forms and images on other sites" do
    config = pages_config
    config.shoutcast_mount = "/night"
    server, port = start_pages_server(config)
    source = open_pages_source(port, "/night")
    admin = "Authorization: #{PAGES_ADMIN_AUTH}\r\n"

    form = "#{admin}Sec-Fetch-Site: cross-site\r\nSec-Fetch-Mode: navigate\r\n"
    page(port, "POST /admin/killsource?mount=/night", form)[0].should start_with("HTTP/1.0 403")
    image = "#{admin}Sec-Fetch-Site: cross-site\r\nSec-Fetch-Mode: no-cors\r\n"
    page(port, "GET /admin/metadata?mount=/night&song=Hacked", image)[0].should start_with("HTTP/1.0 403")
    night_mount(server).has_source?.should be_true
    night_mount(server).current_song.should eq("")

    # Scripts, same-origin pages, explicit cross-site fetches, and SHOUTcast pass= links still work.
    page(port, "GET /admin/metadata?mount=/night&song=Script", admin)[0].should start_with("HTTP/1.0 200")
    same = "#{admin}Sec-Fetch-Site: same-origin\r\nSec-Fetch-Mode: cors\r\n"
    page(port, "POST /admin/metadata?mount=/night&song=Dashboard", same)[0].should start_with("HTTP/1.0 200")
    cors = "#{admin}Sec-Fetch-Site: cross-site\r\nSec-Fetch-Mode: cors\r\n"
    page(port, "POST /admin/metadata?mount=/night&song=Panel", cors)[0].should start_with("HTTP/1.0 200")
    page(port, "GET /admin.cgi?mode=updinfo&pass=admin&song=Link", "Sec-Fetch-Site: cross-site\r\nSec-Fetch-Mode: navigate\r\n")[0].should start_with("HTTP/1.0 200")
    night_mount(server).current_song.should eq("Link")
  ensure
    source.try(&.close)
    server.try(&.stop)
  end

  it "removes a fallback set at runtime" do
    config = pages_config
    server, port = start_pages_server(config)
    admin = "Authorization: #{PAGES_ADMIN_AUTH}\r\n"

    page(port, "POST /admin/fallbacks?mount=/night&fallback=/backup", admin)[0].should start_with("HTTP/1.0 200")
    config.fallback_for("/night").should eq("/backup")
    page(port, "POST /admin/fallbacks?mount=/night&fallback=", admin)[1].should eq("Fallback removed")
    config.fallback_for("/night").should be_nil
  ensure
    server.try(&.stop)
  end
end

describe Config do
  it "derives public_url from hostname and port unless it is set" do
    config = Config.new
    config.hostname = "radio.example"
    config.port = 9000
    config.public_url.should eq("http://radio.example:9000")
    config.public_url = "https://stream.example"
    config.public_url.should eq("https://stream.example")
  end
end
