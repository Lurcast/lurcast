require "./spec_helper"

describe Config do
  it "loads the remaining streaming services" do
    config = Config.from_yaml <<-YAML
      host: 127.0.0.1
      port: 8000
      admin_password: admin
      source_password: source
      burst_size: 65536
      queue_size: 524288
      metadata_interval: 16000
      header_timeout: 10
      source_timeout: 15
      tls_port: 8443
      tls_cert: cert.pem
      tls_key: key.pem
      shoutcast_port: 8001
      shoutcast_mount: /shoutcast
      public_url: https://radio.example
      admin_email: admin@example.com
      fallbacks:
        /live: /backup
      fallback_override: true
      auth_url: https://auth.example/check
      yp_urls:
        - https://dir.example/yp
      relays:
        - url: https://upstream.example/live.ogg
          mount: /relay.ogg
          username: relay
          password: secret
          retry_delay: 2
          on_demand: true
      master_url: https://master.example:8443
      master_username: relay
      master_password: master-secret
      master_update_interval: 30
      relays_on_demand: true
      YAML

    config.tls_port.should eq(8443)
    config.burst_size.should eq(65_536)
    config.queue_size.should eq(524_288)
    config.metadata_interval.should eq(16_000)
    config.header_timeout_for.should eq(10)
    config.source_timeout_for.should eq(15)
    config.shoutcast_mount.should eq("/shoutcast")
    config.fallback_for("/live").should eq("/backup")
    config.migrate_legacy_settings!
    config.plugins["url_auth"]["url"].should eq("https://auth.example/check")
    config.plugins["yp"]["urls"].as_a.should eq(["https://dir.example/yp"])
    config.relays.first.url.should eq("https://upstream.example/live.ogg")
    config.relays.first.mount.should eq("/relay.ogg")
    config.relays.first.retry_delay.should eq(2)
    config.relays.first.on_demand?.should be_true
    config.master_url.should eq("https://master.example:8443")
    config.master_update_interval.should eq(30)
    config.relays_on_demand?.should be_true
    config.log_level.should eq(Log::Severity::Info)
  end

  it "moves settings from before the plugins into their sections" do
    config = Config.from_yaml <<-YAML
      admin_email: ops@example.com
      access_log: /tmp/lurcast-access.log
      auth_url: https://auth.example/check
      auth_timeout: 3
      yp_urls: [https://dir.example/yp]
      webhooks:
        - url: https://hooks.example/radio
          events: [song.changed]
      webhook_timeout: 7
      YAML
    config.validate!

    config.plugins["access_log"]["path"].should eq("/tmp/lurcast-access.log")
    config.plugins["url_auth"]["timeout"].should eq(3)
    config.plugins["yp"]["touch_interval"].should eq(60)
    config.plugins["webhooks"]["timeout"].should eq(7)
    config.plugins["webhooks"]["endpoints"][0]["events"].as_a.should eq(["song.changed"])
    config.auth_url.should be_nil
    config.validate! # moving them again changes nothing
    Lurcast::Plugins.build(config).map(&.name).should contain("url_auth")

    both = Config.from_yaml("access_log: /tmp/a.log\nplugins: {access_log: {path: /tmp/b.log}}")
    expect_raises(ArgumentError, /access_log has moved to plugins.access_log/) { both.validate! }
  end

  it "rejects unknown configuration keys" do
    expect_raises(YAML::ParseException, /Unknown yaml attribute/) do
      Config.from_yaml("porrt: 8000\n")
    end
  end

  it "accepts buffer_size as a legacy burst_size alias" do
    config = Config.from_yaml("buffer_size: 32768\n")

    config.burst_size.should eq(32_768)
    config.to_yaml.should_not contain("buffer_size:")
  end

  it "rejects service URLs without a host" do
    config = Config.new
    config.auth_url = "http:///auth"

    expect_raises(ArgumentError, /Invalid plugins.url_auth: url must be an http or https URL/) { config.validate! }

    config.plugins.clear
    config.relays = [RelayConfig.new("https:///stream", "/relay")]
    expect_raises(ArgumentError, /include a host/) { config.validate! }

    config.relays = [RelayConfig.new("https://radio.example/stream", "/relay", username: "relay")]
    expect_raises(ArgumentError, /configured together/) { config.validate! }
  end

  it "keeps the connection burst within the listener queue" do
    config = Config.new
    config.burst_size = 1024
    config.queue_size = 512

    expect_raises(ArgumentError, /burst_size must not exceed queue_size/) { config.validate! }
  end

  it "applies relay and fallback environment settings" do
    names = ["LURCAST_BURST_SIZE", "LURCAST_QUEUE_SIZE", "LURCAST_METADATA_INTERVAL", "LURCAST_FALLBACK_OVERRIDE", "LURCAST_MASTER_UPDATE_INTERVAL", "LURCAST_RELAYS_ON_DEMAND"]
    previous = names.to_h { |name| {name, ENV[name]?} }
    ENV["LURCAST_BURST_SIZE"] = "32768"
    ENV["LURCAST_QUEUE_SIZE"] = "262144"
    ENV["LURCAST_METADATA_INTERVAL"] = "16000"
    ENV["LURCAST_FALLBACK_OVERRIDE"] = "false"
    ENV["LURCAST_MASTER_UPDATE_INTERVAL"] = "45"
    ENV["LURCAST_RELAYS_ON_DEMAND"] = "yes"

    config = Config.new
    config.apply_env
    config.burst_size.should eq(32_768)
    config.queue_size.should eq(262_144)
    config.metadata_interval.should eq(16_000)
    config.fallback_override?.should be_false
    config.master_update_interval.should eq(45)
    config.relays_on_demand?.should be_true
  ensure
    previous.try do |values|
      values.each do |name, value|
        if value
          ENV[name] = value
        else
          ENV.delete(name)
        end
      end
    end
  end

  it "overrides stream limits and fallbacks per mount" do
    config = Config.from_yaml <<-YAML
      burst_size: 65536
      queue_size: 524288
      metadata_interval: 8192
      fallback_override: true
      mounts:
        /live:
          burst_size: 32768
          queue_size: 262144
          metadata_interval: 16000
          max_listeners: 25
          max_listener_duration: 3600
          fallback: /backup
          fallback_override: false
          fallback_when_full: true
      YAML
    config.validate!

    config.burst_size_for("/live").should eq(32_768)
    config.queue_size_for("/live").should eq(262_144)
    config.metadata_interval_for("/live").should eq(16_000)
    config.max_listeners_for("/live").should eq(25)
    config.max_listener_duration_for("/live").should eq(3600)
    config.fallback_for("/live").should eq("/backup")
    config.fallback_override_for?("/live").should be_false
    config.fallback_when_full?("/live").should be_true

    config.burst_size_for("/other").should eq(65_536)
    config.metadata_interval_for("/relay", 12_345).should eq(12_345)
  end

  it "updates a runtime fallback" do
    config = Config.new

    config.set_fallback("/live", "/backup")

    config.fallback_for("/live").should eq("/backup")
  end

  it "rejects invalid mount-specific stream limits" do
    config = Config.from_yaml <<-YAML
      mounts:
        /live:
          burst_size: 1024
          queue_size: 512
      YAML

    expect_raises(ArgumentError, /mount.*burst_size must not exceed queue_size/) { config.validate! }
  end
end
