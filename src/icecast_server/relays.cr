class IcecastServer
  private def start_background_services
    return if @services_started.swap(true)

    @extensions.each(&.start(self))
    @config.relays.each { |relay| register_relay(relay) }
    if master_url = @config.master_url
      master_url = master_url.rstrip('/')
      master_password = @config.master_password || raise ArgumentError.new("master password is required")
      spawn master_relay_loop(master_url, master_password), name: "master relay"
    end
    spawn rate_limit_cleanup_loop, name: "rate limit cleanup"
    spawn history_loop, name: "listener history"
  end

  private def rate_limit_cleanup_loop
    while running?
      interruptible_sleep(@config.rate_limit_window)
      cutoff = Time.instant - @config.rate_limit_window.seconds
      @limits_mutex.synchronize do
        @requests.reject! do |_ip, requests|
          requests.reject! { |time| time < cutoff }
          requests.empty?
        end
      end
    end
  end

  private def relay_loop(relay : RelayConfig)
    while running? && relay_registered?(relay)
      wait_for_relay_request(relay.mount) if relay.on_demand?
      break unless running? && relay_registered?(relay)
      begin
        relay_once(relay)
      rescue ex
        Log.warn { "Relay #{relay.mount} failed: #{ex.message}" }
      ensure
        interruptible_sleep(relay.retry_delay) if running?
      end
    end
  end

  private def relay_once(relay : RelayConfig)
    uri = URI.parse(relay.url)
    headers = HTTP::Headers{
      "Accept-Encoding" => "identity",
      "Icy-MetaData"    => "1",
      "User-Agent"      => SERVER_ID,
    }
    HTTP::Client.new(uri) do |client|
      client.connect_timeout = @config.timeout.seconds
      client.read_timeout = @config.source_timeout_for.seconds
      if username = relay.username
        client.basic_auth(username, relay.password || "")
      end
      client.get(uri.request_target, headers) do |response|
        raise IO::Error.new("upstream returned #{response.status_code}") unless response.status.success?
        body = response.body_io
        begin
          unless mountpoint = attach_source(relay.mount, body, response.headers, SourceProtocol::Relay)
            raise IO::Error.new("local mount is busy")
          end
          raise IO::Error.new("relay was removed") unless track_relay_source(relay, body)
          metadata_interval = icy_metadata_interval(response.headers)
          read_relay_source(body, mountpoint, relay, metadata_interval)
        ensure
          untrack_relay_source(relay.mount, body)
          release_source(relay.mount, mountpoint, body) if mountpoint
        end
      end
    end
  end

  private def read_relay_source(source : IO, mountpoint : MountPoint, relay : RelayConfig, metadata_interval : Int32?)
    buffer = Bytes.new(16_384)
    remaining = metadata_interval
    while running? && relay_registered?(relay) && (!relay.on_demand? || relay_requested?(relay.mount) || mountpoint.listener_count > 0)
      slice = remaining ? buffer[0, Math.min(remaining, buffer.size)] : buffer
      count = source.read(slice)
      break if count == 0
      mountpoint.publish(buffer[0, count])
      if remaining
        remaining -= count
        if remaining == 0
          read_relay_metadata(source, mountpoint)
          remaining = metadata_interval
        end
      end
    end
  end

  private def read_relay_metadata(source : IO, mountpoint : MountPoint)
    blocks = source.read_byte || raise IO::EOFError.new
    return if blocks == 0

    payload = Bytes.new(blocks.to_i * 16)
    source.read_fully(payload)
    text = String.new(payload, truncate_at_null: true).scrub
    prefix = "StreamTitle='"
    start = text.index(prefix)
    return unless start
    start += prefix.bytesize
    finish = text.index("';", start)
    return unless finish
    mountpoint.update_metadata(text[start, finish - start].gsub("\\'", "'").gsub("\\\\", "\\"))
  end

  private def register_relay(relay : RelayConfig, master = false) : Bool
    added = @relays_mutex.synchronize do
      next false if @relays.has_key?(relay.mount)
      @relays[relay.mount] = relay
      @master_relays.add(relay.mount) if master
      true
    end
    spawn relay_loop(relay), name: "relay" if added
    added
  end

  private def relay_registered?(relay : RelayConfig) : Bool
    @relays_mutex.synchronize { @relays[relay.mount]? == relay }
  end

  private def track_relay_source(relay : RelayConfig, source : IO) : Bool
    @relays_mutex.synchronize do
      next false unless @relays[relay.mount]? == relay
      @relay_sources[relay.mount] = source
      true
    end
  end

  private def untrack_relay_source(mount : String, source : IO)
    @relays_mutex.synchronize do
      @relay_sources.delete(mount) if @relay_sources[mount]? == source
    end
  end

  private def request_relay(mount : String) : Bool
    @relays_mutex.synchronize do
      relay = @relays[mount]?
      next false unless relay.try(&.on_demand?)
      @relay_demand[mount] += 1
      true
    end
  end

  private def relay_requested?(mount : String) : Bool
    @relays_mutex.synchronize { @relay_demand[mount] > 0 }
  end

  private def clear_relay_request(mount : String)
    @relays_mutex.synchronize do
      remaining = @relay_demand[mount] - 1
      if remaining.positive?
        @relay_demand[mount] = remaining
      else
        @relay_demand.delete(mount)
      end
    end
  end

  private def wait_for_relay_request(mount : String)
    until !running? || !@relays_mutex.synchronize { @relays.has_key?(mount) } || relay_requested?(mount)
      sleep 100.milliseconds
    end
  end

  private def wait_for_mount(mount : String) : MountPoint?
    deadline = Time.instant + @config.timeout.seconds
    while running? && Time.instant < deadline
      if point = resolve_mount(mount)
        return point
      end
      sleep 10.milliseconds
    end
    nil
  end

  private def master_relay_loop(master_url : String, master_password : String)
    while running?
      begin
        update_master_relays(fetch_master_mounts(master_url, master_password), master_url, master_password)
      rescue ex
        Log.warn { "Master relay discovery failed: #{ex.message}" }
      ensure
        interruptible_sleep(@config.master_update_interval) if running?
      end
    end
  end

  private def fetch_master_mounts(master_url : String, master_password : String) : Array(String)
    uri = URI.parse("#{master_url}/admin/streamlist.txt")
    HTTP::Client.new(uri) do |client|
      client.connect_timeout = @config.timeout.seconds
      client.read_timeout = @config.timeout.seconds
      client.basic_auth(@config.master_username, master_password)
      mounts = Set(String).new
      bytes_read = 0
      client.get(uri.request_target, HTTP::Headers{"User-Agent" => SERVER_ID}) do |response|
        raise IO::Error.new("master returned #{response.status_code}") unless response.status.success?
        while line = response.body_io.gets('\n', 8193, chomp: true)
          bytes_read += line.bytesize
          raise IO::Error.new("master stream list is too large") if line.bytesize > 8192 || bytes_read > 1_048_576
          if mount = exact_mount(line.strip)
            mounts.add(mount)
            break if mounts.size >= @config.max_sources
          end
        end
      end
      mounts.to_a
    end
  end

  private def update_master_relays(mounts : Array(String), master_url : String, master_password : String)
    stale_sources = @relays_mutex.synchronize do
      removed = @master_relays - mounts.to_set
      removed.compact_map do |mount|
        @relays.delete(mount)
        @relay_demand.delete(mount)
        @master_relays.delete(mount)
        @relay_sources.delete(mount)
      end
    end
    stale_sources.each { |source| source.close rescue nil }

    mounts.each do |mount|
      relay = RelayConfig.new(
        "#{master_url}#{mount}",
        mount,
        username: @config.master_username,
        password: master_password,
        on_demand: @config.relays_on_demand?
      )
      register_relay(relay, master: true)
    end
  end

  private def exact_mount(path : String) : String?
    path if valid_mount?(path)
  end
end
