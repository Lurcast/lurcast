require "./spec_helper"

# A plugin that exists only in the specs, to test what every plugin gets from `Plugin`.
class Lurcast::Plugins::SpecEcho < Lurcast::Plugin
  register "spec_echo"

  class Settings < Plugin::Settings
    getter word : String = "hello"

    def validate!(config : Config) : Nil
      invalid("word must not be empty") if word.empty?
    end
  end

  getter reloads = [] of String?

  def reload(settings : Settings?) : Nil
    @settings = settings if settings
    @reloads << settings.try(&.word)
  end

  @[Route("GET", "/spec-echo")]
  private def echo(context : Context) : Nil
    context.text(settings.word)
  end

  @[Route("GET", "/spec-echo/", prefix: true)]
  private def echo_path(context : Context) : Nil
    context.text(context.path)
  end

  @[Route("GET", "/spec-echo-param")]
  @[Route("POST", "/spec-echo-param")]
  private def echo_param(context : Context) : Nil
    context.text(context.param("q"))
  end

  @[Route("POST", "/admin/spec-echo", admin: true)]
  private def admin_echo(context : Context) : Nil
    context.json({user: context.access.user, mount: context.mount})
  end
end

private alias SpecEcho = Lurcast::Plugins::SpecEcho

private def echo_config(section : String? = "word: hi") : Config
  config = Config.new
  config.host = "127.0.0.1"
  config.source_password = "secret"
  config.admin_password = "admin"
  config.plugins = section ? {"spec_echo" => YAML.parse(section)} : {} of String => YAML::Any
  config
end

private def request(port : Int32, request_line : String, headers = "") : Tuple(String, String)
  socket = TCPSocket.new("127.0.0.1", port)
  socket.read_timeout = 2.seconds
  socket.print "#{request_line} HTTP/1.0\r\n#{headers}\r\n"
  socket.flush
  head = read_head(socket)
  {head, socket.gets_to_end}
ensure
  socket.try(&.close)
end

describe Lurcast::Plugin do
  it "builds from its section, which is off without one" do
    SpecEcho.build(nil, Config.new).should be_nil
    SpecEcho.build(YAML.parse("enabled: false"), Config.new).should be_nil
    plugin = SpecEcho.build(YAML.parse("word: hi"), Config.new).should_not be_nil
    plugin.name.should eq("spec_echo")
    plugin.settings.word.should eq("hi")
    Lurcast::Plugins.keys.should contain("spec_echo")
    Lurcast::Plugins.keys.should contain("cover_art")
  end

  it "reports invalid settings with the section name" do
    expect_raises(ArgumentError, "Invalid plugins.spec_echo: word must not be empty") do
      SpecEcho.build(YAML.parse("word: ''"), Config.new)
    end
    expect_raises(ArgumentError, /Invalid plugins.spec_echo: .*unknown/i) do
      SpecEcho.build(YAML.parse("unknown: 1"), Config.new)
    end
    expect_raises(ArgumentError, "unknown plugins: nope") do
      config = echo_config
      config.plugins["nope"] = YAML.parse("{}")
      Lurcast::Plugins.validate!(config)
    end
  end

  it "passes reloaded settings on, and keeps the current ones when they are invalid" do
    plugin = SpecEcho.build(YAML.parse("word: hi"), Config.new).should_not be_nil
    plugin.config_reloaded(echo_config("word: ''"))
    plugin.reloads.should be_empty
    plugin.settings.word.should eq("hi")
    plugin.config_reloaded(echo_config("word: bye"))
    plugin.settings.word.should eq("bye")
    plugin.config_reloaded(echo_config(nil))
    plugin.reloads.should eq(["bye", nil])
  end

  it "serves the plugins' dashboard scripts before the dashboard's own" do
    script = Lurcast::Plugins.dashboard_script
    %w[hls cover_art listener_logins].each { |name| script.should contain("register(\"#{name}\",") }
    page = Templates.admin
    page.index!("/_lurcast/plugins.js").should be < page.index!("/_lurcast/admin.js")
  end

  it "routes requests to the methods marked with @[Route]" do
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(echo_config)
    spawn server.serve(listener)
    Fiber.yield

    head, body = request(port, "GET /spec-echo")
    head.should start_with("HTTP/1.0 200")
    body.should eq("hi")
    head, body = request(port, "HEAD /spec-echo")
    head.should start_with("HTTP/1.0 200")
    body.should be_empty
    request(port, "GET /spec-echo/a/b")[1].should eq("/spec-echo/a/b")
    request(port, "POST /spec-echo")[0].should_not start_with("HTTP/1.0 200")

    request(port, "POST /spec-echo-param?q=x")[1].should eq("x")
    head, body = request(port, "GET /spec-echo-param")
    head.should start_with("HTTP/1.0 400")
    JSON.parse(body)["error"].should eq("q is required")

    head, _ = request(port, "POST /admin/spec-echo?mount=/live")
    head.should start_with("HTTP/1.0 401")
    head.should contain(%(realm="Lurcast Admin"))
    admin = "Authorization: Basic #{Base64.strict_encode("admin:admin")}\r\n"
    JSON.parse(request(port, "POST /admin/spec-echo?mount=live", admin)[1]).should eq(JSON.parse(%({"user":"admin","mount":"/live"})))
    request(port, "POST /admin/spec-echo", admin)[0].should start_with("HTTP/1.0 404")
  ensure
    server.try(&.stop)
  end
end
