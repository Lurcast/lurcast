require "xml"

class IcecastServer
  # Attaches an Ultravox source, or returns the NAK reason.
  private def attach_uvox_source(mount : String, client : TCPSocket, headers : HTTP::Headers) : MountPoint | String
    return "Stream Rejected" if source_rejection(mount, headers)
    attach_source(mount, client, headers, SourceProtocol::ShoutcastV2) || "Stream In Use"
  end

  private def handle_uvox_source(client : TCPSocket, address : String)
    authenticated = false
    configured_mime = false
    configured_bitrate = false
    configured_buffer = false
    configured_payload = false
    cipher_requested = false
    headers = HTTP::Headers.new
    metadata_fragments = {} of UInt16 => Array(Bytes?)
    binary_fragments = {} of UInt16 => Array(Bytes?)
    mount = nil.as(String?)
    mountpoint = nil.as(MountPoint?)
    sync_read = true

    loop do
      message = Ultravox.read(client, sync_read: sync_read)
      sync_read = false
      case message.type
      when 0x1009
        return uvox_nak(client, message.type, "Sequence Error") if authenticated
        cipher_requested = true
        Ultravox.write(client, message.type, "ACK:#{@config.uvox_cipher_key}\0")
      when 0x1001
        return uvox_nak(client, message.type, "Sequence Error") if authenticated
        credentials = Ultravox.text(message.payload).split(':', 4)
        return uvox_nak(client, message.type, "2.1:Parse Error") unless credentials.size == 4
        version, sid_text, encoded_user, encoded_password = credentials
        sid = sid_text.to_i?
        mount = sid.try { |value| @config.shoutcast_mount_for(value) }
        unless version == "2.1" && sid && mount
          Ultravox.write(client, message.type, "NAK:2.1:Stream ID Error\0")
          return
        end
        begin
          user = cipher_requested ? Ultravox.decrypt(encoded_user, @config.uvox_cipher_key) : encoded_user
          password = cipher_requested ? Ultravox.decrypt(encoded_password, @config.uvox_cipher_key) : encoded_password
        rescue ArgumentError
          return uvox_nak(client, message.type, "2.1:Parse Error")
        end
        unless uvox_source_authorized?(mount, address, user, password)
          Ultravox.write(client, message.type, "NAK:2.1:Deny\0")
          return
        end
        authenticated = true
        Ultravox.write(client, message.type, "ACK:2.1:Allow\0")
      when 0x1040
        return uvox_nak(client, message.type, "Sequence Error") unless authenticated && mountpoint.nil?
        content_type = Ultravox.text(message.payload)
        unless {"audio/mpeg", "audio/aac", "audio/aacp", "audio/ogg", "audio/speex"}.includes?(content_type)
          return uvox_nak(client, message.type, "Mime Type Error")
        end
        headers["Content-Type"] = content_type
        configured_mime = true
        Ultravox.write(client, message.type, "ACK\0")
      when 0x1002
        return uvox_nak(client, message.type, "Sequence Error") unless authenticated && mountpoint.nil?
        return uvox_nak(client, message.type, "Bit Rate Error") unless pair = uvox_pair(message.payload)
        average, maximum = pair
        return uvox_nak(client, message.type, "Bit Rate Error") unless average.positive? && average <= maximum <= 320
        headers["Icy-Br"] = average.to_s
        configured_bitrate = true
        Ultravox.write(client, message.type, "ACK\0")
      when 0x1003
        return uvox_nak(client, message.type, "Sequence Error") unless authenticated && mountpoint.nil?
        return uvox_nak(client, message.type, "Buffer Size Error") unless pair = uvox_pair(message.payload)
        desired, minimum = pair
        available = @config.queue_size_for(mount || @config.shoutcast_mount) // 1024
        return uvox_nak(client, message.type, "Buffer Size Error") unless minimum.positive? && desired >= minimum && minimum <= available
        configured_buffer = true
        Ultravox.write(client, message.type, "ACK:#{Math.min(desired, available)}\0")
      when 0x1008
        return uvox_nak(client, message.type, "Sequence Error") unless authenticated && mountpoint.nil?
        return uvox_nak(client, message.type, "Payload Size Error") unless pair = uvox_pair(message.payload)
        desired, minimum = pair
        return uvox_nak(client, message.type, "Payload Size Error") unless minimum.positive? && desired >= minimum && minimum <= Ultravox::MAX_PAYLOAD
        configured_payload = true
        Ultravox.write(client, message.type, "ACK:#{Math.min(desired, Ultravox::MAX_PAYLOAD)}\0")
      when 0x1100, 0x1101, 0x1102, 0x1103
        return uvox_nak(client, message.type, "Sequence Error") unless authenticated && mountpoint.nil?
        key = {"Icy-Name", "Icy-Genre", "Icy-URL", "Icy-Pub"}[(message.type - 0x1100).to_i]
        headers[key] = Ultravox.text(message.payload)
        Ultravox.write(client, message.type, "ACK\0")
      when 0x1004
        return uvox_nak(client, message.type, "Sequence Error") if mountpoint
        unless authenticated && configured_mime && configured_bitrate && configured_buffer && configured_payload && mount
          return uvox_nak(client, message.type, "Configuration Error")
        end
        point = attach_uvox_source(mount, client, headers)
        return uvox_nak(client, message.type, point) if point.is_a?(String)
        mountpoint = point
        set_read_timeout(client, @config.source_timeout_for)
        Ultravox.write(client, message.type, "ACK:Data transfer mode\0")
      when 0x1006
        return uvox_nak(client, message.type, "Sequence Error") unless mountpoint
        mountpoint.update_metadata("")
        metadata_fragments.clear
        Ultravox.write(client, message.type, "ACK\0")
      when 0x1005
        break
      when 0x3902, 0x4000..0x4fff
        handle_uvox_cacheable(mountpoint, message, metadata_fragments, binary_fragments)
      else
        unless Ultravox.data_type?(message.type)
          Log.debug { "Ignoring Ultravox message 0x#{message.type.to_s(16)}" }
          next
        end
        raise ArgumentError.new("Ultravox data arrived before standby") unless mountpoint
        raise ArgumentError.new("Ultravox data type does not match configured mime type") unless Ultravox.data_type_matches?(message.type, headers["Content-Type"])
        mountpoint.publish(message.payload)
      end
    end
  ensure
    release_source(mount, mountpoint, client) if mount && mountpoint
  end

  private def uvox_pair(payload : Bytes) : Tuple(Int32, Int32)?
    first_text, separator, second_text = Ultravox.text(payload).partition(':')
    return if separator.empty?
    first = first_text.to_i?
    second = second_text.to_i?
    {first, second} if first && second
  end

  private def uvox_nak(client : IO, type : UInt16, reason : String)
    Ultravox.write(client, type, "NAK:#{reason}\0")
  end

  # Song titles (XML, 0x3902), and other items for the extensions; ignored before the source goes live.
  private def handle_uvox_cacheable(mountpoint : MountPoint?, message : Ultravox::Message, metadata : Hash(UInt16, Array(Bytes?)), others : Hash(UInt16, Array(Bytes?)))
    return unless mountpoint
    if message.type == 0x3902
      handle_uvox_metadata(mountpoint, message.payload, metadata)
    else
      handle_uvox_other(mountpoint, message.type, message.payload, others)
    end
  end

  # Collects one fragment of a metadata message that spans several Ultravox messages. Returns the
  # whole message once every fragment has arrived.
  private def uvox_fragment(payload : Bytes, fragments : Hash(UInt16, Array(Bytes?))) : Bytes?
    raise ArgumentError.new("invalid Ultravox metadata") if payload.size < 6
    id = IO::ByteFormat::BigEndian.decode(UInt16, payload[0, 2])
    span = IO::ByteFormat::BigEndian.decode(UInt16, payload[2, 2]).to_i
    index = IO::ByteFormat::BigEndian.decode(UInt16, payload[4, 2]).to_i
    raise ArgumentError.new("invalid Ultravox metadata fragments") unless 1 <= id <= 32 && 1 <= span <= 32 && 1 <= index <= span

    parts = fragments.put_if_absent(id) { Array(Bytes?).new(span, nil) }
    raise ArgumentError.new("inconsistent Ultravox metadata span") unless parts.size == span
    parts[index - 1] = payload[6..].dup
    return unless parts.all?(&.nil?.!)
    fragments.delete(id)
    whole = IO::Memory.new
    parts.each { |part| part.try { |value| whole.write(value) } }
    whole.to_slice
  end

  # Passes a metadata item the server doesn't use itself to the extensions, once it is whole.
  private def handle_uvox_other(mountpoint : MountPoint, type : UInt16, payload : Bytes, fragments : Hash(UInt16, Array(Bytes?)))
    data = uvox_fragment(payload, fragments) || return
    notify_extensions("handle Ultravox metadata for #{mountpoint.mount}", &.ultravox_metadata(mountpoint.mount, type, data))
  end

  private def handle_uvox_metadata(mountpoint : MountPoint, payload : Bytes, fragments : Hash(UInt16, Array(Bytes?)))
    whole = uvox_fragment(payload, fragments) || return
    xml = String.new(whole)
    document = XML.parse(xml)
    title = document.xpath_string("string(//TIT2)")
    title = document.xpath_string("string(//SONGTITLE)") if title.empty?
    mountpoint.update_metadata(title) unless title.empty?
  rescue ex : XML::Error
    Log.debug { "Invalid SHOUTcast XML metadata: #{ex.message}" }
  end
end
