require "./spec_helper"

describe Lurcast do
  it "configures parallel execution from Crystal's worker setting" do
    Lurcast.configure_execution_context

    Fiber::ExecutionContext.default.capacity.should eq(Fiber::ExecutionContext.default_workers_count)
  ensure
    Lurcast.configure_execution_context(2)
  end

  it "limits each listener backlog by bytes" do
    queue = MountPoint::ListenerQueue.new(5)
    packet = Bytes[1, 2, 3, 4]

    queue.enqueue(packet).should be_true
    queue.bytesize.should eq(4)
    queue.enqueue(Bytes[5, 6]).should be_false
    queue.receive?.should eq(packet)
    queue.bytesize.should eq(0)
  ensure
    queue.try(&.close)
  end

  it "uses Crystal's native snake-case JSON representation for source protocols" do
    SourceProtocol::ShoutcastV1.to_json.should eq(%("shoutcast_v1"))
    SourceProtocol.from_json(%("shoutcast_v2")).should eq(SourceProtocol::ShoutcastV2)
  end

  it "builds a correctly padded ICY metadata block" do
    mount = MountPoint.new("/radio", metadata_interval: 4)
    mount.apply_headers(HTTP::Headers{"Content-Type" => "application/octet-stream"})
    listener = IO::Memory.new
    mount.add_listener(listener, "127.0.0.1", true)
    mount.update_metadata("Artist - Song")
    mount.publish(Bytes.new(4))
    wait_until { listener.size > 4 }

    block = listener.to_slice[4..]
    block[0].should be > 0
    block.size.should eq(1 + block[0].to_i * 16)
    String.new(block[1..]).should contain("StreamTitle='Artist - Song';")
  ensure
    mount.try(&.remove_listener(listener)) if listener
  end

  it "sends an empty ICY block until the song changes" do
    mount = MountPoint.new("/radio", metadata_interval: 4)
    mount.apply_headers(HTTP::Headers{"Content-Type" => "application/octet-stream"})
    listener = IO::Memory.new
    mount.add_listener(listener, "127.0.0.1", true)
    mount.update_metadata("First Song")
    mount.publish(Bytes[1, 2, 3, 4])
    wait_until { listener.size > 4 }

    first_size = 1 + listener.to_slice[4].to_i * 16
    mount.publish(Bytes[5, 6, 7, 8])
    wait_until { listener.size >= 4 + first_size + 5 }
    unchanged_offset = 4 + first_size + 4
    listener.to_slice[unchanged_offset].should eq(0)

    mount.update_metadata("Second Song")
    mount.publish(Bytes[9, 10, 11, 12])
    wait_until { listener.size > unchanged_offset + 5 }
    changed_offset = unchanged_offset + 1 + 4
    listener.to_slice[changed_offset].should be > 0
  ensure
    mount.try(&.remove_listener(listener)) if listener
  end

  it "closes a listener's queue and connection together" do
    io = IO::Memory.new
    listener = MountPoint::Listener.new(io, "127.0.0.1", false, "/radio", MountPoint.new("/radio"))

    listener.close

    listener.queue.closed?.should be_true
    io.closed?.should be_true
  end

  it "renders escaped stream links and an empty state" do
    mount = MountPoint.new("/rock&roll")
    mount.update_station(name: "Rock & <Roll>")

    html = Templates.index([mount])

    html.should contain("Rock &amp; &lt;Roll&gt;")
    html.should contain(%(src="/rock&amp;roll"))
    Templates.index([] of MountPoint).should contain("No active streams.")
  end

  it "starts a mid-stream MP3 burst on a valid frame" do
    mount = MountPoint.new("/radio", 1024)
    mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/mpeg"})
    false_sync = Bytes[0xff, 0xfb, 0xe0, 0x00]
    frame = mp3_frame
    mount.publish(false_sync + Bytes[1, 2, 3] + frame + frame)

    mount.initial_burst[0, 4].should eq(Bytes[0xff, 0xfb, 0x90, 0x64])
  end

  it "parses MPEG 1, 2, and 2.5 Layer III frame details" do
    mpeg1 = MP3.parse_header(Bytes[0xff, 0xfb, 0x90, 0x64]) || raise "expected MPEG 1 header"
    mpeg1.version.should eq("1")
    mpeg1.layer.should eq(3)
    mpeg1.bitrate_kbps.should eq(128)
    mpeg1.sample_rate_hz.should eq(44_100)
    mpeg1.channels.should eq(2)
    mpeg1.frame_size.should eq(417)

    mpeg2 = MP3.parse_header(Bytes[0xff, 0xf3, 0x80, 0xc0]) || raise "expected MPEG 2 header"
    mpeg2.version.should eq("2")
    mpeg2.layer.should eq(3)
    mpeg2.bitrate_kbps.should eq(64)
    mpeg2.sample_rate_hz.should eq(22_050)
    mpeg2.channels.should eq(1)
    mpeg2.samples_per_frame.should eq(576)

    mpeg25 = MP3.parse_header(Bytes[0xff, 0xe3, 0x80, 0x00]) || raise "expected MPEG 2.5 header"
    mpeg25.version.should eq("2.5")
    mpeg25.sample_rate_hz.should eq(11_025)
  end

  it "observes MP3 details when a frame header is split across source writes" do
    mount = MountPoint.new("/radio")
    mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/mpeg"})
    frame = mp3_frame
    mount.publish(frame[0, 200])
    mount.publish(frame[200..] + frame)

    details = mount.mp3_info || raise "expected MP3 details"
    details.bitrate_kbps.should eq(128)
    details.sample_rate_hz.should eq(44_100)
    details.channels.should eq(2)
  end

  it "filters garbage and publishes only complete MP3 frames" do
    mount = MountPoint.new("/radio")
    mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/mpeg"})
    listener = IO::Memory.new
    mount.add_listener(listener, "127.0.0.1", false)
    frame = mp3_frame

    mount.publish(Bytes[1, 2, 3] + frame[0, 200])
    mount.publish(frame[200..] + frame)

    wait_until { listener.size == frame.size * 2 }
    listener.to_slice.should eq(frame + frame)
    mount.initial_burst.should eq(frame + frame)

    mount.publish(Bytes[9] + frame + frame)
    wait_until { listener.size == frame.size * 4 }
    listener.to_slice.should eq(frame + frame + frame + frame)
  ensure
    mount.try(&.remove_listener(listener)) if listener
  end

  it "infers fragmented free-format MP3 frames including padding" do
    mount = MountPoint.new("/free.mp3", 900)
    mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/mpeg"})
    first = free_mp3_frame(1_u8)
    second = free_mp3_frame(2_u8, padding: true)
    third = free_mp3_frame(3_u8)
    audio = first + second + third

    mount.publish(Bytes[9, 8, 7] + audio[0, 600])
    mount.publish(audio[600..])

    mount.initial_burst.should eq(second + third)
    details = mount.mp3_info || raise "expected free-format MP3 details"
    details.bitrate_kbps.should eq(128)
    details.frame_size.should eq(417)
    details.free_format_bytes.should eq(417)
  end

  it "streams real CBR, VBR, and free-format MP3 fixtures" do
    ["cbr.mp3", "vbr.mp3", "free-format.mp3"].each do |name|
      audio = mp3_fixture(name)
      located = MP3.find_frame(audio, require_complete: true) || raise "expected MP3 frame in #{name}"
      located.offset.should eq(name == "cbr.mp3" ? 76 : 0)

      mount = MountPoint.new("/#{name}", 8192)
      mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/mpeg"})
      split = audio.size // 3
      mount.publish(audio[0, split])
      mount.publish(audio[split..])

      mount.initial_burst.should eq(audio[located.offset..])
      details = mount.mp3_info || raise "expected MP3 details for #{name}"
      details.sample_rate_hz.should eq(44_100)
      details.free_format_bytes.should eq(name == "free-format.mp3" ? 417 : nil)
    end
  end

  it "resynchronizes after a corrupt frame in a real MP3 fixture" do
    audio = mp3_fixture("cbr.mp3")
    first = MP3.find_frame(audio, require_complete: true) || raise "expected first MP3 frame"
    second_offset = first.offset + first.frame.frame_size
    audio[first.offset] = 0_u8

    mount = MountPoint.new("/corrupt.mp3", 8192)
    mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/mpeg"})
    mount.publish(audio[0, second_offset + 100])
    mount.publish(audio[second_offset + 100..])

    mount.initial_burst.should eq(audio[second_offset..])
  end

  it "aligns fragmented AAC streams to complete ADTS frames" do
    AAC::Frame.new(4, 2, 44_100, 2, 20, 1024).transport.adts?.should be_true

    mount = MountPoint.new("/radio.aac")
    mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/aac"})
    listener = IO::Memory.new
    mount.add_listener(listener, "127.0.0.1", false)
    frame = aac_frame

    mount.publish(frame[0, 3])
    mount.publish(frame[3..] + frame)

    wait_until { listener.size == frame.size * 2 }
    listener.to_slice.should eq(frame + frame)
    mount.initial_burst.should eq(frame + frame)
  ensure
    mount.try(&.remove_listener(listener)) if listener
  end

  it "aligns fragmented AAC streams to complete LATM/LOAS frames" do
    mount = MountPoint.new("/radio.aac")
    mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/aacp"})
    listener = IO::Memory.new
    mount.add_listener(listener, "127.0.0.1", false)
    frame = loas_frame

    mount.publish(Bytes[1, 2, 3] + frame[0, 5])
    mount.publish(frame[5..] + frame)

    wait_until { listener.size == frame.size * 2 }
    listener.to_slice.should eq(frame + frame)
    mount.initial_burst.should eq(frame + frame)
  ensure
    mount.try(&.remove_listener(listener)) if listener
  end

  it "uses the standard Ultravox codec message types" do
    {
      0x7000_u16 => "audio/mpeg",
      0x8001_u16 => "audio/ogg",
      0x8002_u16 => "audio/speex",
      0x8003_u16 => "audio/aac",
    }.each do |type, content_type|
      Ultravox.data_type?(type).should be_true
      Ultravox.data_type_matches?(type, content_type).should be_true
    end
    Ultravox.data_type_matches?(0x8003_u16, "audio/aacp").should be_true
    Ultravox.data_type?(0x8004_u16).should be_false
  end

  it "prepends cached Ogg headers and resumes on a complete page" do
    mount = MountPoint.new("/radio.ogg", 80)
    mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/ogg"})
    head = ogg_page(0_u32, 2_u8, "OpusHead".to_slice)
    tags = ogg_page(1_u32, 0_u8, "OpusTags".to_slice)
    audio = ogg_page(2_u32, 0_u8, Bytes.new(20, 7_u8))
    stream = IO::Memory.new
    stream.write(head)
    stream.write(tags)
    stream.write(audio)
    bytes = stream.to_slice
    mount.publish(bytes[0, 13])
    mount.publish(bytes[13, 31])
    mount.publish(bytes[44..])

    mount.initial_burst.should eq(bytes)
    mount.supports_icy_metadata?.should be_false
  end

  it "ignores corrupt Ogg pages while caching headers" do
    mount = MountPoint.new("/radio.ogg", 256)
    mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/ogg"})
    corrupt = ogg_page(0_u32, 2_u8, "OpusHead".to_slice)
    corrupt[28] ^= 0xff_u8
    head = ogg_page(0_u32, 2_u8, "OpusHead".to_slice)
    tags = ogg_page(1_u32, 0_u8, "OpusTags".to_slice)
    corrupt_audio = ogg_page(2_u32, 0_u8, Bytes[1, 2, 3])
    corrupt_audio[28] ^= 0xff_u8
    audio = ogg_page(3_u32, 0_u8, Bytes[4, 5, 6])

    mount.publish(corrupt + head + tags + corrupt_audio + audio)

    mount.initial_burst.should eq(head + tags + audio)
  end

  it "replaces cached headers when an Ogg stream is chained" do
    mount = MountPoint.new("/radio.ogg", 256)
    mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/ogg"})
    mount.publish(ogg_page(0_u32, 2_u8, "OpusHead".to_slice))
    mount.publish(ogg_page(1_u32, 0_u8, "OpusTags".to_slice))
    mount.publish(ogg_page(2_u32, 0_u8, Bytes[1, 2, 3]))

    head = ogg_page(0_u32, 2_u8, "OpusHead".to_slice, 2_u32)
    tags = ogg_page(1_u32, 0_u8, "OpusTags".to_slice, 2_u32)
    audio = ogg_page(2_u32, 0_u8, Bytes[4, 5, 6], 2_u32)
    mount.publish(head)
    mount.publish(tags)
    mount.publish(audio)

    mount.initial_burst.should eq(head + tags + audio)
  end

  it "preserves every logical stream header in multiplexed Ogg bursts" do
    mount = MountPoint.new("/radio.ogg", 128)
    mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/ogg"})
    opus_head = ogg_page(0_u32, 2_u8, "OpusHead".to_slice, 10_u32)
    theora_head = ogg_page(0_u32, 2_u8, Bytes[0x80] + "theora".to_slice, 20_u32)
    opus_tags = ogg_page(1_u32, 0_u8, "OpusTags".to_slice, 10_u32)
    theora_comment = ogg_page(1_u32, 0_u8, Bytes[0x81] + "theora".to_slice, 20_u32)
    theora_setup = ogg_page(2_u32, 0_u8, Bytes[0x82] + "theora".to_slice, 20_u32)
    continued_audio = ogg_page(2_u32, 1_u8, Bytes[1, 2, 3], 10_u32)
    video = ogg_page(3_u32, 0_u8, Bytes[4, 5, 6], 20_u32)
    audio = ogg_page(3_u32, 0_u8, Bytes[7, 8, 9], 10_u32)
    next_video = ogg_page(4_u32, 0_u8, Bytes[10, 11, 12], 20_u32)

    {opus_head, theora_head, opus_tags, theora_comment, theora_setup,
     continued_audio, video, audio, next_video}.each { |page| mount.publish(page) }

    headers = opus_head + theora_head + opus_tags + theora_comment + theora_setup
    mount.initial_burst.should eq(headers + video + audio + next_video)
  end

  it "moves live listeners between fallback mounts without closing them" do
    primary = MountPoint.new("/live")
    fallback = MountPoint.new("/backup", 512)
    fallback.apply_headers(HTTP::Headers{"Content-Type" => "audio/mpeg"})
    frames = mp3_frame + mp3_frame
    fallback.publish(frames)
    listener = IO::Memory.new
    primary.add_listener(listener, "127.0.0.1", false, "/live")

    fallback.adopt_listeners(primary.detach_listeners)

    primary.listener_count.should eq(0)
    fallback.listener_count.should eq(1)
    listener.closed?.should be_false
    wait_until { listener.to_slice.size >= mp3_frame.size }
    listener.to_slice.should eq(mp3_frame)
  end

  it "only moves fallback listeners between compatible stream formats" do
    mp3 = MountPoint.new("/live")
    mp3.apply_headers(HTTP::Headers{"Content-Type" => "audio/mpeg"})
    ogg = MountPoint.new("/backup.ogg")
    ogg.apply_headers(HTTP::Headers{"Content-Type" => "audio/ogg"})

    mp3.compatible_with?(ogg).should be_false
  end

  it "does not let a slow listener block the source or other listeners" do
    mount = MountPoint.new("/radio")
    mount.apply_headers(HTTP::Headers{"Content-Type" => "application/octet-stream"})
    slow = BlockingWriteIO.new
    fast = IO::Memory.new
    mount.add_listener(slow, "slow", false)
    mount.add_listener(fast, "fast", false)
    published = Channel(Nil).new

    spawn do
      mount.publish(Bytes[1, 2, 3, 4])
      published.send(nil)
    end

    receive(slow.write_started)
    receive(published, 100.milliseconds)
    wait_until { fast.to_slice == Bytes[1, 2, 3, 4] }
  ensure
    slow.try(&.release_write.close)
    mount.try(&.disconnect)
  end

  it "disconnects a listener when its byte queue is full" do
    mount = MountPoint.new("/radio", burst_size: 4, queue_size: 4)
    mount.apply_headers(HTTP::Headers{"Content-Type" => "application/octet-stream"})
    slow = BlockingWriteIO.new
    mount.add_listener(slow, "slow", false)

    mount.publish(Bytes[1, 2, 3, 4])
    receive(slow.write_started)
    mount.publish(Bytes[5, 6, 7, 8])
    mount.includes_listener?(slow).should be_true

    mount.publish(Bytes[9])
    mount.includes_listener?(slow).should be_false
  ensure
    slow.try(&.release_write.close)
    mount.try(&.disconnect)
  end

  it "authenticates a source and streams audio with per-listener ICY metadata" do
    config = Config.new
    config.host = "127.0.0.1"
    config.source_password = "secret"
    config.admin_password = "admin"
    config.metadata_interval = 32
    config.max_connections_per_ip = 10
    listener_socket = TCPServer.new("127.0.0.1", 0)
    port = listener_socket.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(listener_socket)
    Fiber.yield

    unauthorized = TCPSocket.new("127.0.0.1", port)
    unauthorized.print "PUT /radio HTTP/1.0\r\n\r\n"
    read_head(unauthorized).should start_with("HTTP/1.0 401")
    unauthorized.close

    source = TCPSocket.new("127.0.0.1", port)
    source.print "PUT /radio HTTP/1.1\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: audio/mpeg\r\nIce-Name: Spec Radio\r\nExpect: 100-continue\r\n\r\n"
    read_head(source).should start_with("HTTP/1.1 100")

    metadata = TCPSocket.new("127.0.0.1", port)
    metadata.print "GET /admin/metadata?mount=/radio&mode=updinfo&song=Artist+-+Song HTTP/1.0\r\nAuthorization: Basic YWRtaW46YWRtaW4=\r\n\r\n"
    read_head(metadata).should start_with("HTTP/1.0 200")
    metadata.close

    listener = TCPSocket.new("127.0.0.1", port)
    listener.read_timeout = 2.seconds
    listener.print "GET /radio HTTP/1.0\r\nIcy-MetaData: 1\r\n\r\n"
    response = read_head(listener)
    response.should start_with("HTTP/1.0 200")
    response.should contain("icy-metaint: #{config.metadata_interval}")

    stream = IO::Memory.new
    frame = mp3_frame
    while stream.size < config.metadata_interval + frame.size
      stream.write(frame)
    end
    audio = stream.to_slice
    source.write(audio)
    source.flush

    received_audio = Bytes.new(config.metadata_interval)
    listener.read_fully(received_audio)
    received_audio.should eq(audio[0, config.metadata_interval])
    metadata_length = (listener.read_byte || raise IO::EOFError.new).to_i * 16
    metadata_payload = Bytes.new(metadata_length)
    listener.read_fully(metadata_payload)
    String.new(metadata_payload).should contain("StreamTitle='Artist - Song';")

    listener.close
    source.close
    server.stop
  ensure
    server.try(&.stop)
  end
end
