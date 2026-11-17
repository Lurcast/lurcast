require "../spec_helper"

private alias ACMESupport = Lurcast::ACMESupport
private alias AcmePlugin = Lurcast::Plugins::ACME

private FIXTURES = File.join(__DIR__, "..", "fixtures", "acme")

private def acme_config(yaml : String, data_dir : String? = "/tmp/lurcast-acme") : Config
  config = Config.new
  config.host = "127.0.0.1"
  config.data_dir = data_dir
  config.plugins = {"acme" => YAML.parse(yaml)}
  config
end

private def build_acme(yaml : String, config : Config? = nil) : AcmePlugin?
  config ||= acme_config(yaml)
  AcmePlugin.build(config.plugins["acme"], config)
end

private def acme_error(yaml : String, config : Config? = nil) : String
  expect_raises(ArgumentError) { build_acme(yaml, config) }.message.to_s
end

private def free_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  server.local_address.port
ensure
  server.try(&.close)
end

private def acme_temp_dir : String
  path = File.join(Dir.tempdir, "lurcast-acme-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(path)
  path
end

private def http_get(port : Int32, path : String, host = "a.example.com") : Tuple(String, String)
  socket = TCPSocket.new("127.0.0.1", port)
  socket.read_timeout = 2.seconds
  socket.print "GET #{path} HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n"
  head = read_head(socket)
  {head, socket.gets_to_end}
ensure
  socket.try(&.close)
end

# The DNS names of the certificate served on *port*, or nil while nothing answers there.
private def served_names(port : Int32, hostname : String) : Array(String)?
  socket = TCPSocket.new("127.0.0.1", port)
  context = OpenSSL::SSL::Context::Client.new
  context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
  tls = OpenSSL::SSL::Socket::Client.new(socket, context, sync_close: true, hostname: hostname)
  certificate = tls.peer_certificate || return
  names = ACMESupport.dns_names(LibCrypto.x509_get_ext_d2i(certificate.to_unsafe, LibCrypto::NID_subject_alt_name, nil, nil))
  tls.close
  names
rescue Socket::ConnectError | OpenSSL::SSL::Error | IO::Error
  nil
end

private def start_acme_server(config : Config) : Tuple(IcecastServer, AcmePlugin, Int32)
  listener = TCPServer.new("127.0.0.1", 0)
  server = IcecastServer.new(config)
  plugin = server.extensions.compact_map(&.as?(AcmePlugin)).first
  spawn server.serve(listener)
  Fiber.yield
  {server, plugin, listener.local_address.port}
end

describe Lurcast::ACMESupport do
  it "generates P-256 keys that survive a PEM round trip" do
    key = ACMESupport::Key.generate
    pem = key.to_pem
    pem.should start_with("-----BEGIN PRIVATE KEY-----")
    copy = ACMESupport::Key.from_pem(pem)
    copy.jwk.should eq(key.jwk)
    x, y = key.public_coordinates
    {x.size, y.size}.should eq({32, 32})
    ACMESupport::Key.generate.jwk.should_not eq(key.jwk)
  end

  it "rejects keys that are not PEM private keys" do
    expect_raises(ACMESupport::CryptoError) { ACMESupport::Key.from_pem("not a key") }
  end

  it "computes the RFC 7638 example thumbprint" do
    jwk = {
      "kty" => "RSA",
      "n"   => "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw",
      "e"   => "AQAB",
    }
    ACMESupport.thumbprint(jwk).should eq("NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs")
  end

  it "converts ECDSA signatures between DER and raw form" do
    raw = Bytes.new(64) { |index| index < 32 ? 0x80_u8 : (index == 32 ? 0_u8 : 0x01_u8) }
    der = ACMESupport.ecdsa_raw_to_der(raw)
    der[0].should eq(0x30)
    ACMESupport.ecdsa_der_to_raw(der).should eq(raw)
  end

  it "signs JWS requests that libcrypto verifies" do
    key = ACMESupport::Key.generate
    client = ACMESupport::Client.new("https://ca.example/directory", key, ACMESupport::Challenges.new)
    client.nonce = "nonce-1"
    body = JSON.parse(client.jws("https://ca.example/new-account", %({"termsOfServiceAgreed":true}), use_jwk: true))
    header = JSON.parse(String.new(Base64.decode(body["protected"].as_s)))
    header["alg"].should eq("ES256")
    header["nonce"].should eq("nonce-1")
    header["url"].should eq("https://ca.example/new-account")
    header["jwk"]["kty"].should eq("EC")
    header["jwk"]["crv"].should eq("P-256")
    header["kid"]?.should be_nil
    String.new(Base64.decode(body["payload"].as_s)).should eq(%({"termsOfServiceAgreed":true}))

    signature = Base64.decode(body["signature"].as_s)
    signature.size.should eq(64)
    signing_input = "#{body["protected"].as_s}.#{body["payload"].as_s}"
    key.verify(signing_input, signature).should be_true
    key.verify("#{signing_input}x", signature).should be_false
    ACMESupport::Key.generate.verify(signing_input, signature).should be_false
  end

  it "uses an empty payload for POST-as-GET" do
    client = ACMESupport::Client.new("https://ca.example/directory", ACMESupport::Key.generate, ACMESupport::Challenges.new)
    client.nonce = "nonce-2"
    JSON.parse(client.jws("https://ca.example/order/1", nil))["payload"].should eq("")
  end

  it "builds a CSR with every domain as a subjectAltName" do
    key = ACMESupport::Key.generate
    domains = ["radio.example.com", "www.radio.example.com", "stream.example.org"]
    names, signed = ACMESupport.csr_details(ACMESupport.csr(key, domains), key)
    names.should eq(domains)
    signed.should be_true
    ACMESupport.csr_details(ACMESupport.csr(key, domains), ACMESupport::Key.generate)[1].should be_false
  end

  it "reads a certificate's names and validity, checking its key" do
    pem = File.read(File.join(FIXTURES, "certificate.pem"))
    key = ACMESupport::Key.from_pem(File.read(File.join(FIXTURES, "certificate-key.pem")))
    info = ACMESupport::CertificateInfo.parse(pem, key).should_not be_nil
    info.names.should eq(["a.example.com", "b.example.com"])
    info.not_after.year.should eq(2126)
    info.not_before.should be < Time.utc
    info.covers?(["b.example.com"]).should be_true
    info.covers?(["a.example.com", "c.example.com"]).should be_false
    ACMESupport::CertificateInfo.parse(pem, ACMESupport::Key.generate).should be_nil
  end
end

describe Lurcast::ACMESupport::HTTPResponder do
  it "answers known challenge tokens and 404s the rest" do
    challenges = ACMESupport::Challenges.new
    challenges.add("token-1", "token-1.thumb")
    responder = ACMESupport::HTTPResponder.new(challenges, ["a.example.com"], 443, false)

    response = responder.answer(HTTP::Request.new("GET", "/.well-known/acme-challenge/token-1"))
    {response.status, response.body}.should eq({200, "token-1.thumb"})
    responder.answer(HTTP::Request.new("GET", "/.well-known/acme-challenge/other")).status.should eq(404)
    responder.answer(HTTP::Request.new("POST", "/.well-known/acme-challenge/token-1")).status.should eq(405)
    responder.answer(HTTP::Request.new("GET", "/live")).status.should eq(404)

    challenges.remove("token-1")
    responder.answer(HTTP::Request.new("GET", "/.well-known/acme-challenge/token-1")).status.should eq(404)
  end

  it "redirects other requests to HTTPS on a configured domain" do
    challenges = ACMESupport::Challenges.new
    challenges.add("token-1", "token-1.thumb")
    responder = ACMESupport::HTTPResponder.new(challenges, ["a.example.com", "b.example.com"], 8443, true)

    response = responder.answer(HTTP::Request.new("GET", "/live?x=1", HTTP::Headers{"Host" => "B.example.com:80"}))
    response.status.should eq(301)
    response.headers["Location"].should eq("https://b.example.com:8443/live?x=1")
    responder.answer(HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => "evil.example"})).headers["Location"].should eq("https://a.example.com:8443/")
    responder.answer(HTTP::Request.new("GET", "/.well-known/acme-challenge/token-1")).status.should eq(200)

    standard = ACMESupport::HTTPResponder.new(challenges, ["a.example.com"], 443, true)
    standard.answer(HTTP::Request.new("GET", "/status")).headers["Location"].should eq("https://a.example.com/status")
  end

  it "writes HTTP/1.1 responses" do
    io = IO::Memory.new
    ACMESupport::HttpResponse.new(200, "abc").write(io)
    io.to_s.should eq("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc")
  end
end

describe Lurcast::Plugins::ACME do
  base = "domains: [radio.example.com]\naccept_terms: true\n"

  it "is off without a section and builds with valid settings" do
    AcmePlugin.build(nil, Config.new).should be_nil
    build_acme("enabled: false").should be_nil
    plugin = build_acme("domains: [Radio.Example.com., www.radio.example.com, radio.example.com]\naccept_terms: true\nemail: ops@example.com").should_not be_nil
    plugin.domains.should eq(["radio.example.com", "www.radio.example.com"])
    plugin.settings.https_port.should eq(443)
    plugin.settings.http_port.should eq(80)
    plugin.settings.directory.should eq(AcmePlugin::LETS_ENCRYPT)
    plugin.storage_directory.should eq("/tmp/lurcast-acme/acme/acme-v02.api.letsencrypt.org")
  end

  it "rejects invalid settings with clear messages" do
    acme_error(base, acme_config(base, nil)).should contain("data_dir is required")
    acme_error("accept_terms: true").should contain("at least one domain")
    acme_error("domains: ['*.example.com']\naccept_terms: true").should contain("wildcard")
    acme_error("domains: [192.0.2.1]\naccept_terms: true").should contain("IP address")
    acme_error("domains: [bad_name.example.com]\naccept_terms: true").should contain("not a valid domain")
    acme_error("domains: [localhost]\naccept_terms: true").should contain("not a valid domain")
    acme_error("domains: [#{(1..101).map { |index| "d#{index}.example.com" }.join(",")}]\naccept_terms: true").should contain("at most 100")
    acme_error("domains: [radio.example.com]").should contain("accept_terms must be true")
    acme_error("domains: [radio.example.com]\naccept_terms: false").should contain("accept_terms must be true")
    acme_error(base + "email: nope").should contain("email")
    acme_error(base + "https_port: 0").should contain("https_port must be between")
    acme_error(base + "http_port: 70000").should contain("http_port must be between")
    acme_error(base + "https_port: 8000").should contain("https_port 8000 is already used by port")
    acme_error(base + "http_port: 8000").should contain("http_port 8000 is already used by port")
    acme_error(base + "https_port: 8443\nhttp_port: 8443").should contain("must differ")
    acme_error(base + "http_port: 0\nredirect_http: true").should contain("redirect_http needs http_port")
    acme_error(base + "renew_days: 0").should contain("renew_days")
    acme_error(base + "directory: http://ca.example/directory").should contain("https URL")
    acme_error(base + "directory: ftp://ca.example/directory").should contain("https URL")
    acme_error(base + "unknown: 1").should contain("Invalid plugins.acme")

    shoutcast = acme_config(base + "http_port: 8001")
    shoutcast.shoutcast_port = 8001
    acme_error(base + "http_port: 8001", shoutcast).should contain("http_port 8001 is already used by shoutcast_port")

    tls = acme_config(base)
    tls.tls_port = 8443
    acme_error(base, tls).should contain("use either the acme plugin or your own certificate")
  end

  it "allows a plain HTTP directory on localhost and turning off the challenge port" do
    plugin = build_acme(base + "directory: http://127.0.0.1:14000/dir\nhttp_port: 0").should_not be_nil
    plugin.settings.http_port.should eq(0)
    plugin.storage_directory.should end_with("/acme/127.0.0.1_14000")
  end

  it "is validated with the rest of the configuration" do
    config = acme_config("domains: ['*.example.com']\naccept_terms: true")
    expect_raises(ArgumentError, /wildcard/) { config.validate! }
  end

  it "renews when the certificate is missing, expiring, or lacks a domain" do
    plugin = build_acme("domains: [a.example.com, b.example.com]\naccept_terms: true\nrenew_days: 30").should_not be_nil
    now = Time.utc
    fresh = ACMESupport::CertificateInfo.new(["a.example.com", "b.example.com"], now - 1.day, now + 89.days)
    plugin.renewal_reason(nil).should eq("no certificate yet")
    plugin.renewal_reason(fresh).should be_nil
    plugin.renewal_reason(fresh, now + 60.days).to_s.should contain("expires")
    plugin.renewal_reason(ACMESupport::CertificateInfo.new(["a.example.com"], now - 1.day, now + 89.days)).should eq("the domain list changed")
    plugin.renew_at(fresh).should eq(fresh.not_after - 30.days)

    # A six-day certificate is renewed halfway through, not on every check.
    short = ACMESupport::CertificateInfo.new(["a.example.com", "b.example.com"], now, now + 6.days)
    plugin.renew_at(short).should eq(short.not_after - 3.days)
  end

  it "serves a stored certificate over HTTPS and answers challenges on both ports" do
    data_dir = acme_temp_dir
    https_port = free_port
    http_port = free_port
    config = acme_config(<<-YAML, data_dir)
      domains: [a.example.com, b.example.com]
      accept_terms: true
      https_port: #{https_port}
      http_port: #{http_port}
      redirect_http: true
      directory: http://127.0.0.1:9/directory
      YAML
    config.validate!
    storage = File.join(data_dir, "acme", "127.0.0.1_9")
    Dir.mkdir_p(storage)
    File.copy(File.join(FIXTURES, "certificate.pem"), File.join(storage, "certificate.pem"))
    File.copy(File.join(FIXTURES, "certificate-key.pem"), File.join(storage, "certificate.key"))

    server, plugin, port = start_acme_server(config)
    begin
      names = nil
      wait_until(5.seconds) { !(names = served_names(https_port, "a.example.com")).nil? }
      names.should eq(["a.example.com", "b.example.com"])
      plugin.certificate.try(&.names).should eq(["a.example.com", "b.example.com"])

      plugin.challenges.add("tok", "tok.thumb")
      head, body = http_get(port, "/.well-known/acme-challenge/tok")
      head.should match(/\AHTTP\/1\.[01] 200/)
      body.should eq("tok.thumb")

      wait_until(5.seconds) { (http_get(http_port, "/") rescue nil) != nil }
      head, body = http_get(http_port, "/.well-known/acme-challenge/tok")
      head.should start_with("HTTP/1.1 200")
      body.should eq("tok.thumb")
      head, _ = http_get(http_port, "/.well-known/acme-challenge/missing")
      head.should start_with("HTTP/1.1 404")
      head, _ = http_get(http_port, "/live", host: "b.example.com")
      head.should start_with("HTTP/1.1 301")
      head.should contain("Location: https://b.example.com:#{https_port}/live")

      # A replaced certificate is picked up without restarting the HTTPS listener.
      File.copy(File.join(FIXTURES, "renewed-key.pem"), File.join(storage, "certificate.key"))
      File.copy(File.join(FIXTURES, "renewed.pem"), File.join(storage, "certificate.pem"))
      plugin.config_reloaded(config)
      wait_until(5.seconds) { served_names(https_port, "a.example.com").try(&.includes?("c.example.com")) || false }
      plugin.certificate.try(&.names).should eq(["a.example.com", "b.example.com", "c.example.com"])
    ensure
      server.stop
      FileUtils.rm_rf(data_dir)
    end
  end

  # Runs against Pebble, Let's Encrypt's test CA, when PEBBLE_DIRECTORY is set (for example
  # https://localhost:14000/dir), with LURCAST_ACME_CA_FILE pointing at Pebble's root (pebble.minica.pem).
  # Pebble must run with PEBBLE_VA_ALWAYS_VALID=1 unless it can reach the challenge port.
  if directory = ENV["PEBBLE_DIRECTORY"]?
    it "obtains a certificate from Pebble and serves it" do
      data_dir = acme_temp_dir
      https_port = free_port
      http_port = ENV["PEBBLE_HTTP_PORT"]?.try(&.to_i) || free_port
      domains = ["lurcast-#{Random::Secure.hex(4)}.example.com", "www.lurcast.example.com"]
      config = acme_config(<<-YAML, data_dir)
        domains: [#{domains.join(", ")}]
        email: ops@example.com
        accept_terms: true
        https_port: #{https_port}
        http_port: #{http_port}
        directory: #{directory}
        YAML
      config.validate!
      server, plugin, _ = start_acme_server(config)
      begin
        names = nil
        wait_until(90.seconds) { !(names = served_names(https_port, domains.first)).nil? }
        names.not_nil!.sort.should eq(domains.sort) # ameba:disable Lint/NotNil
        storage = plugin.storage_directory
        {"account.key", "certificate.key", "certificate.pem"}.each do |file|
          (File.info(File.join(storage, file)).permissions.value & 0o077).should eq(0)
        end
        (File.info(storage).permissions.value & 0o077).should eq(0)
        info = plugin.certificate.should_not be_nil
        plugin.renewal_reason(info).should be_nil

        # The same account orders again (as a renewal does).
        account_key = ACMESupport::Key.from_pem(File.read(File.join(storage, "account.key")))
        tls = OpenSSL::SSL::Context::Client.new
        ENV["LURCAST_ACME_CA_FILE"]?.try { |path| tls.ca_certificates = path }
        client = ACMESupport::Client.new(directory, account_key, plugin.challenges, tls: tls)
        chain = client.obtain([domains.first], ACMESupport::Key.generate)
        ACMESupport::CertificateInfo.parse(chain).try(&.names).should eq([domains.first])
      ensure
        server.stop
        FileUtils.rm_rf(data_dir)
      end
    end
  end
end
