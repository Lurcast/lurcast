require "./spec_helper"

private MOD_SOURCE_AUTH = "Basic c291cmNlOnNlY3JldA==" # source:secret
private MOD_ADMIN_AUTH  = "Basic YWRtaW46YWRtaW4="     # admin:admin

private def basic(user : String, password : String) : String
  "Basic #{Base64.strict_encode("#{user}:#{password}")}"
end

private def mod_config : Config
  config = Config.new
  config.host = "127.0.0.1"
  config.source_password = "secret"
  config.admin_password = "admin"
  config.max_connections_per_ip = 50
  config
end

private def start_mod_server(config : Config, extension : Lurcast::Extension? = nil) : Tuple(IcecastServer, Int32)
  listener = TCPServer.new("127.0.0.1", 0)
  port = listener.local_address.as(Socket::IPAddress).port
  server = IcecastServer.new(config)
  extension.try { |ext| server.add_extension(ext) }
  spawn server.serve(listener)
  Fiber.yield
  {server, port}
end

private def mod_request(port : Int32, request_line : String, headers = "") : Tuple(String, String)
  socket = TCPSocket.new("127.0.0.1", port)
  socket.read_timeout = 2.seconds
  socket.print "#{request_line} HTTP/1.0\r\n#{headers}\r\n"
  head = read_head(socket)
  {head, socket.gets_to_end}
ensure
  socket.try(&.close)
end

private def admin_get(port : Int32, path : String, auth = MOD_ADMIN_AUTH) : Tuple(String, String)
  mod_request(port, "GET #{path}", "Authorization: #{auth}\r\n")
end

private def admin_post(port : Int32, path : String, auth = MOD_ADMIN_AUTH) : Tuple(String, String)
  mod_request(port, "POST #{path}", "Authorization: #{auth}\r\nContent-Length: 0\r\n")
end

private def open_mod_source(port : Int32, mount : String) : TCPSocket
  source = TCPSocket.new("127.0.0.1", port)
  source.print "PUT #{mount} HTTP/1.1\r\nAuthorization: #{MOD_SOURCE_AUTH}\r\nContent-Type: audio/mpeg\r\nExpect: 100-continue\r\n\r\n"
  read_head(source).should start_with("HTTP/1.1 100")
  source.write(mp3_frame)
  source.flush
  source
end

private def open_listener(port : Int32, mount : String, user_agent = "SpecPlayer") : Tuple(TCPSocket, String)
  socket = TCPSocket.new("127.0.0.1", port)
  socket.read_timeout = 2.seconds
  socket.print "GET #{mount} HTTP/1.0\r\nUser-Agent: #{user_agent}\r\n\r\n"
  {socket, read_head(socket)}
end

private def temp_path(name : String) : String
  dir = File.join(Dir.tempdir, "lurcast-#{name}-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  dir
end

# Grants `owner`/`station-pass` access to /mine only, the way the Hosting edition grants customers theirs.
private class StationLogins < Lurcast::Extension
  def admin_login(user : String, password : String) : Array(String)?
    ["/mine"] if user == "owner" && password == "station-pass"
  end
end

private def network(entry : String) : IPNetwork
  IPNetwork.parse?(entry) || raise "invalid #{entry}"
end

describe IPNetwork do
  it "matches addresses and ranges, with IPv4-mapped IPv6 as IPv4" do
    network("203.0.113.0/24").includes?("203.0.113.99").should be_true
    network("203.0.113.0/24").includes?("203.0.114.1").should be_false
    network("203.0.113.7").includes?("::ffff:203.0.113.7").should be_true
    network("2001:db8::/32").includes?("[2001:db8:1::5]").should be_true
    IPNetwork.parse?("10.0.0.0/33").should be_nil
    IPNetwork.parse?("example.com").should be_nil
  end
end

describe BanList do
  it "matches by address range, player text, mount, and expiry" do
    bans = BanList.new(nil)
    now = Time.utc
    bans.add(:address, "198.51.100.0/24", mount: nil, reason: "abuse", created_by: "admin", now: now)
    bans.add(:user_agent, "StreamRipper", mount: "/live", reason: nil, created_by: "admin", now: now)
    bans.add(:address, "192.0.2.1", mount: nil, reason: nil, created_by: "admin", duration: 1.hour, now: now)

    bans.match("198.51.100.20", "VLC", "/any", now).try(&.reason).should eq("abuse")
    bans.match("203.0.113.1", "Mozilla streamripper/1.6", "/live", now).should_not be_nil
    bans.match("203.0.113.1", "StreamRipper", "/other", now).should be_nil
    bans.match("192.0.2.1", "VLC", "/live", now + 30.minutes).should_not be_nil
    bans.match("192.0.2.1", "VLC", "/live", now + 2.hours).should be_nil
    bans.list(now + 2.hours).size.should eq(2)
  end

  it "refuses ranges that are too wide, short player text, and bad addresses" do
    bans = BanList.new(nil)
    expect_raises(ArgumentError, /too wide/) { bans.add(:address, "0.0.0.0/0", mount: nil, reason: nil, created_by: "admin") }
    expect_raises(ArgumentError, /at least/) { bans.add(:user_agent, "Mo", mount: nil, reason: nil, created_by: "admin") }
    expect_raises(ArgumentError, /not an IP/) { bans.add(:address, "example.com", mount: nil, reason: nil, created_by: "admin") }
    BanList::Kind.parse?("user_agent").should eq(BanList::Kind::UserAgent)
  end

  it "keeps bans in a file, reads it again, and keeps the current bans when the file is broken" do
    path = File.join(temp_path("bans"), "bans.json")
    bans = BanList.new(path)
    ban = bans.add(:address, "203.0.113.7", mount: "/live", reason: "spam", created_by: "admin")
    BanList.new(path).list.map(&.id).should eq([ban.id])

    File.write(path, "[]")
    bans.load
    bans.list.should be_empty

    bans.add(:address, "203.0.113.8", mount: nil, reason: nil, created_by: "admin")
    File.write(path, "{broken")
    bans.load
    bans.list.size.should eq(1)
    bans.remove(bans.list.first.id).should_not be_nil
    bans.list.should be_empty
  end
end

describe ListenerHistory do
  it "averages samples per bucket, counts missing mounts as zero, and shows gaps while the server was down" do
    history = ListenerHistory.new
    start = Time.unix(1_800_000_000 // 300 * 300)
    history.record({"/a" => 4, "/b" => 0}, start)
    history.record({"/a" => 2, "/b" => 1}, start + 1.minute)
    history.record({"/a" => 0, "/b" => 0}, start + 10.minutes)

    chart = history.chart("/a", "day", start + 10.minutes)
    chart.points.size.should eq(288)
    chart.step_seconds.should eq(300)
    chart.points[-3].should eq({start.to_unix, 3.0, 4})
    chart.points[-2].should eq({start.to_unix + 300, nil, nil})
    chart.points[-1].should eq({start.to_unix + 600, 0.0, 0})
    history.chart("/b", "day", start + 10.minutes).points[-3].should eq({start.to_unix, 0.5, 1})
    history.chart(ListenerHistory::TOTAL, "day", start + 10.minutes).points[-3].should eq({start.to_unix, 3.5, 4})
    history.chart("/a", "year", start + 10.minutes).points.size.should eq(365)
    expect_raises(ArgumentError, /range/) { history.chart("/a", "decade") }
  end

  it "saves to a file and reads it back" do
    path = File.join(temp_path("history"), "listener-history.bin")
    now = Time.utc
    history = ListenerHistory.new(path)
    history.record({"/live" => 7}, now)
    history.save
    ListenerHistory.new(path).chart("/live", "week", now).points.last[2].should eq(7)

    File.write(path, "garbage")
    ListenerHistory.new(path).chart("/live", "day", now).points.last.should eq({now.to_unix // 300 * 300, nil, nil})
  end

  it "drops old buckets and forgets mounts" do
    history = ListenerHistory.new
    start = Time.utc
    history.record({"/a" => 1}, start)
    history.record({"/a" => 0}, start + 3.days)
    history.chart("/a", "day", start + 3.days).points.compact_map(&.[2]).sum.should eq(0)
    history.chart("/a", "week", start + 3.days).points.compact_map(&.[2]).max.should eq(1)
    history.forget("/a")
    history.chart("/a", "week", start + 3.days).points.compact_map(&.[2]).max.should eq(0)
  end
end

describe "Bans on the server" do
  it "disconnects and refuses banned listeners, and lifts bans" do
    server, port = start_mod_server(mod_config)
    source = open_mod_source(port, "/live")
    listener, head = open_listener(port, "/live")
    head.should start_with("HTTP/1.0 200")

    status, body = admin_post(port, "/admin/bans?kind=address&value=127.0.0.1&mount=/live&minutes=60&reason=spam")
    status.should start_with("HTTP/1.0 200")
    result = JSON.parse(body)
    result["disconnected"].should eq(1)
    result["ban"]["created_by"].should eq("admin")
    id = result["ban"]["id"].as_s
    wait_until { listener.read(Bytes.new(4096)) == 0 rescue true }

    open_listener(port, "/live")[1].should start_with("HTTP/1.0 403")
    open_listener(port, "/live.m3u8")[1].should start_with("HTTP/1.0 403")
    bans = JSON.parse(admin_get(port, "/admin/api/bans?mount=/live")[1])
    bans["bans"].as_a.map(&.["id"]).should eq([id])
    bans["saved"].should be_false

    admin_post(port, "/admin/bans?kind=address&value=nonsense")[0].should start_with("HTTP/1.0 400")
    admin_post(port, "/admin/bans/remove?id=#{id}")[0].should start_with("HTTP/1.0 200")
    open_listener(port, "/live")[1].should start_with("HTTP/1.0 200")
  ensure
    source.try(&.close)
    server.try(&.stop)
  end

  it "bans players by name" do
    server, port = start_mod_server(mod_config)
    source = open_mod_source(port, "/live")
    admin_post(port, "/admin/bans?kind=user_agent&value=ripper")[0].should start_with("HTTP/1.0 200")
    open_listener(port, "/live", "StreamRipper/1.64")[1].should start_with("HTTP/1.0 403")
    open_listener(port, "/live", "VLC/3.0")[1].should start_with("HTTP/1.0 200")
  ensure
    source.try(&.close)
    server.try(&.stop)
  end

  it "keeps bans and listener history in data_dir" do
    dir = temp_path("data")
    config = mod_config
    config.data_dir = dir
    server, port = start_mod_server(config)
    admin_post(port, "/admin/bans?kind=address&value=203.0.113.7")[0].should start_with("HTTP/1.0 200")
    server.stop
    File.read(File.join(dir, "bans.json")).should contain("203.0.113.7")
    File.exists?(File.join(dir, "listener-history.bin")).should be_true

    server, port = start_mod_server(config)
    JSON.parse(admin_get(port, "/admin/api/bans")[1])["saved"].should be_true
    JSON.parse(admin_get(port, "/admin/api/bans")[1])["bans"].size.should eq(1)
  ensure
    server.try(&.stop)
  end
end

describe "Listener history endpoint" do
  it "serves the server total and mount charts" do
    server, port = start_mod_server(mod_config)
    status, body = admin_get(port, "/admin/api/history?range=week")
    status.should start_with("HTTP/1.0 200")
    chart = JSON.parse(body)
    chart["mount"].raw.should be_nil
    chart["step_seconds"].should eq(3600)
    chart["points"].size.should eq(168)
    admin_get(port, "/admin/api/history?mount=/live&range=day")[0].should start_with("HTTP/1.0 200")
    admin_get(port, "/admin/api/history?range=forever")[0].should start_with("HTTP/1.0 400")
    admin_get(port, "/admin/api/history", basic("admin", "wrong"))[0].should start_with("HTTP/1.0 401")
  ensure
    server.try(&.stop)
  end
end

describe "Logins limited to some mounts" do
  it "sees and manages only its own mounts" do
    server, port = start_mod_server(mod_config, StationLogins.new)
    mine = open_mod_source(port, "/mine")
    theirs = open_mod_source(port, "/theirs")
    owner = basic("owner", "station-pass")

    admin_get(port, "/admin/api/overview", basic("owner", "wrong"))[0].should start_with("HTTP/1.0 401")
    overview = JSON.parse(admin_get(port, "/admin/api/overview", owner)[1])
    overview["access"].should eq(JSON.parse(%({"user":"owner","full":false})))
    overview["mounts"].as_a.map(&.["mount"]).should eq(["/mine"])
    overview["server"]["default_passwords"].as_a.should be_empty
    overview["server"]["features"]["reload"].should be_false
    overview["server"]["max_sources"].should eq(1)
    JSON.parse(admin_get(port, "/admin/api/overview")[1])["mounts"].size.should eq(2)

    admin_get(port, "/admin/listmounts", owner)[1].should_not contain("/theirs")
    admin_post(port, "/admin/metadata?mount=/mine&song=Mine", owner)[0].should start_with("HTTP/1.0 200")
    admin_post(port, "/admin/metadata?mount=/theirs&song=Theirs", owner)[0].should start_with("HTTP/1.0 401")
    admin_post(port, "/admin/killsource?mount=/theirs", owner)[0].should start_with("HTTP/1.0 404")
    admin_post(port, "/admin/fallbacks?mount=/mine&fallback=/theirs", owner)[0].should start_with("HTTP/1.0 400")
    admin_post(port, "/admin/moveclients?mount=/mine&destination=/theirs", owner)[0].should start_with("HTTP/1.0 400")
    admin_post(port, "/admin/reload", owner)[0].should start_with("HTTP/1.0 403")

    admin_post(port, "/admin/bans?kind=address&value=203.0.113.7", owner)[1].should contain("mount is required")
    admin_post(port, "/admin/bans?kind=address&value=203.0.113.7&mount=/theirs", owner)[0].should start_with("HTTP/1.0 404")
    admin_post(port, "/admin/bans?kind=address&value=203.0.113.8", MOD_ADMIN_AUTH)[0].should start_with("HTTP/1.0 200")
    own = JSON.parse(admin_post(port, "/admin/bans?kind=address&value=203.0.113.7&mount=/mine", owner)[1])["ban"]
    JSON.parse(admin_get(port, "/admin/api/bans", owner)[1])["bans"].as_a.map(&.["id"]).should eq([own["id"]])
    server_ban = JSON.parse(admin_get(port, "/admin/api/bans")[1])["bans"].as_a.find! { |ban| ban["mount"].raw.nil? }
    admin_post(port, "/admin/bans/remove?id=#{server_ban["id"]}", owner)[0].should start_with("HTTP/1.0 404")

    admin_get(port, "/admin/api/history", owner)[0].should start_with("HTTP/1.0 404")
    admin_get(port, "/admin/api/history?mount=/theirs", owner)[0].should start_with("HTTP/1.0 404")
    admin_get(port, "/admin/api/history?mount=/mine", owner)[0].should start_with("HTTP/1.0 200")
    admin_get(port, "/admin/stats.json", owner)[0].should start_with("HTTP/1.0 401")

    admin_post(port, "/admin/killsource?mount=/mine", owner)[0].should start_with("HTTP/1.0 200")
  ensure
    mine.try(&.close)
    theirs.try(&.close)
    server.try(&.stop)
  end
end
