class IcecastServer
  private def handle_shoutcast_source(client : TCPSocket, address : String)
    accepted = begin_request(address)
    unless accepted
      client.print "invalid password\r\n"
      client.flush
      return
    end

    first = client.read_byte
    raise IO::EOFError.new unless first
    if first == Ultravox::SYNC
      handle_uvox_source(client, address)
      return
    end

    password_line = read_shoutcast_line(client, 1024, "SHOUTcast password")
    password = String.build do |io|
      io.write_byte(first)
      io << password_line
    end.strip
    password, separator, sid_text = password.partition(":#")
    sid = separator.empty? ? 1 : sid_text.to_i?
    mount = sid.try { |value| @config.shoutcast_mount_for(value) }
    unless mount && uvox_source_authorized?(mount, address, "source", password)
      client.print "invalid password\r\n"
      client.flush
      return
    end

    client.print "OK2\r\nicy-caps:11\r\n\r\n"
    client.flush
    headers = read_shoutcast_headers(client)
    headers["Content-Type"] ||= "audio/mpeg"
    if reason = source_rejection(mount, headers)
      client.print reason, "\r\n"
      client.flush
      return
    end
    unless mountpoint = attach_source(mount, client, headers, SourceProtocol::ShoutcastV1)
      client.print "Mountpoint in use\r\n"
      client.flush
      return
    end
    set_read_timeout(client, @config.source_timeout_for)
    read_source(client, mountpoint)
  rescue ex : IO::Error
    Log.debug { "SHOUTcast source from #{address} closed: #{ex.message}" }
  rescue ex
    Log.error(exception: ex) { "SHOUTcast source from #{address} failed" }
  ensure
    release_source(mount, mountpoint, client) if mountpoint && mount
    end_request(address) if accepted
    client.close unless client.closed?
  end

  private def read_shoutcast_headers(client : IO) : HTTP::Headers
    headers = HTTP::Headers.new
    bytes_read = 0
    101.times do |index|
      raise ArgumentError.new("too many headers") if index == 100
      line = read_shoutcast_line(client, 8192, "header")
      bytes_read += line.bytesize
      raise ArgumentError.new("headers too large") if bytes_read > HTTP::MAX_HEADERS_SIZE
      break if line.blank?
      key, separator, value = line.partition(':')
      raise ArgumentError.new("invalid header") if separator.empty? || key.blank?
      raise ArgumentError.new("invalid header value") unless headers.add?(key.strip, value.strip)
    end
    headers
  end

  private def read_shoutcast_line(client : IO, limit : Int32, description : String) : String
    line = client.gets('\n', limit + 1)
    raise ArgumentError.new("missing #{description}") unless line
    raise ArgumentError.new("#{description} too long or incomplete") if line.bytesize > limit || !line.ends_with?('\n')
    line
  end
end
