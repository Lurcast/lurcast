require "../spec_helper"

private alias Transcode = Lurcast::Plugins::Transcode

private record OggPageInfo, header_type : UInt8, granule : Int64, serial : UInt32, sequence : UInt32, packets : Array(Bytes)

private def transcode_fixture(name : String) : Bytes
  File.read(File.join(__DIR__, "..", "fixtures", "transcode", name)).to_slice
end

# A `plugins.transcode` section with *yaml* as its list of streams.
private def streams(yaml : String) : YAML::Any
  YAML.parse({"streams" => YAML.parse(yaml)}.to_yaml)
end

private def transcode_config(yaml : String) : Config
  config = Config.new
  config.host = "127.0.0.1"
  config.source_password = "secret"
  config.admin_password = "admin"
  config.max_connections_per_ip = 20
  config.plugins = {"transcode" => streams(yaml)}
  config
end

private def build_transcode(yaml : String) : Transcode?
  Transcode.build(yaml.empty? ? nil : streams(yaml), Config.new)
end

# Splits Ogg data into pages; libogg checks each page's CRC, so a bad checksum loses the page.
private def ogg_pages(data : Bytes, sync = Ogg::Sync.new) : Array(OggPageInfo)
  pages = [] of OggPageInfo
  sync.each_page(data) do |_offset, header, body|
    packets = [] of Bytes
    packet = IO::Memory.new
    offset = 0
    header[26].to_i.times do |index|
      length = header[27 + index].to_i
      packet.write(body[offset, length])
      offset += length
      next if length == 255
      packets << packet.to_slice.dup
      packet.clear
    end
    pages << OggPageInfo.new(header[5], IO::ByteFormat::LittleEndian.decode(Int64, header[6, 8]),
      IO::ByteFormat::LittleEndian.decode(UInt32, header[14, 4]), IO::ByteFormat::LittleEndian.decode(UInt32, header[18, 4]), packets)
  end
  pages
end

# Checks an Ogg Opus stream's headers and pages, decodes its audio with libopus and returns the
# decoded samples (48 kHz, interleaved).
private def verify_ogg_opus(pages : Array(OggPageInfo), channels : Int32) : Array(Float32)
  pages.size.should be > 2
  head = pages[0]
  (head.header_type & 0x02).should_not eq(0)
  head.packets.first[0, 8].should eq("OpusHead".to_slice)
  head.packets.first[9].should eq(channels)
  IO::ByteFormat::LittleEndian.decode(UInt16, head.packets.first[10, 2]).should be > 0
  pages[1].packets.first[0, 8].should eq("OpusTags".to_slice)
  pages[1].granule.should eq(0)

  audio = pages[2..]
  audio.each { |page| (page.header_type & 0x02).should eq(0) }
  audio.map(&.serial).uniq!.should eq([head.serial])
  audio.each_cons_pair { |previous, page| page.granule.should be > previous.granule }
  audio.each_cons_pair { |previous, page| page.sequence.should eq(previous.sequence + 1) }

  error = 0
  decoder = LibOpus.decoder_create(48_000, channels, pointerof(error))
  error.should eq(LibOpus::OK)
  pcm = Slice(Float32).new(5760 * channels)
  samples = [] of Float32
  begin
    audio.each do |page|
      page.packets.each do |packet|
        decoded = LibOpus.decode_float(decoder, packet.to_unsafe, packet.size, pcm.to_unsafe, 5760, 0)
        decoded.should eq(960)
        samples.concat(pcm[0, decoded * channels])
      end
    end
  ensure
    LibOpus.decoder_destroy(decoder)
  end
  samples
end

private def rms(samples : Array(Float32)) : Float64
  Math.sqrt(samples.sum { |sample| sample.to_f64 ** 2 } / samples.size)
end

private def connect_source(port : Int32, mount : String, content_type : String) : TCPSocket
  source = TCPSocket.new("127.0.0.1", port)
  source.print "PUT #{mount} HTTP/1.1\r\nAuthorization: Basic c291cmNlOnNlY3JldA==\r\nContent-Type: #{content_type}\r\n" \
               "Ice-Name: Spec Radio\r\nIce-Genre: Jazz\r\nExpect: 100-continue\r\n\r\n"
  read_head(source).should start_with("HTTP/1.1 100")
  source
end

private def set_title(port : Int32, mount : String, title : String) : Nil
  request = TCPSocket.new("127.0.0.1", port)
  request.print "GET /admin/metadata?mount=#{mount}&song=#{URI.encode_www_form(title)} HTTP/1.0\r\nAuthorization: Basic YWRtaW46YWRtaW4=\r\n\r\n"
  read_head(request).should start_with("HTTP/1.0 200")
  request.close
end

# Sends *data* to *source* over and over, about ten times faster than real time, until *done* closes.
private def loop_audio(source : TCPSocket, data : Bytes, done : Channel(Nil)) : Nil
  spawn do
    offset = 0
    loop do
      select
      when done.receive?
        break
      when timeout(40.milliseconds)
      end
      chunk = data[offset, Math.min(4096, data.size - offset)]
      source.write(chunk)
      source.flush
      offset = (offset + chunk.size) % data.size
    end
  rescue IO::Error
  end
end

describe Lurcast::Plugins::Transcode do
  it "reads and validates its settings" do
    build_transcode("").should be_nil
    build_transcode("[]").should be_nil

    plugin = build_transcode("- {source: /live, mount: /live.opus}").should_not be_nil
    plugin.name.should eq("transcode")
    entry = plugin.entries.first
    {entry.source, entry.mount, entry.bitrate, entry.channels, entry.codec}.should eq({"/live", "/live.opus", 64, 2, "opus"})
    build_transcode("- {source: /live, mount: /live.mp3, codec: mp3}").try(&.entries.first.bitrate).should eq(128)

    chain = build_transcode("[{source: /live, mount: /a.opus, bitrate: 6, channels: 1}, {source: /a.opus, mount: /b.opus, bitrate: 256}]")
    chain.should_not be_nil

    {
      "- {source: live, mount: /live.opus}"                                         => "must start with /",
      "- {source: /live, mount: /}"                                                 => "must start with /",
      "- {source: /live, mount: /live}"                                             => "can't transcode itself",
      "- {source: /live, mount: /live.opus, bitrate: 5}"                            => "6 to 256 kbps",
      "- {source: /live, mount: /live.opus, bitrate: 257}"                          => "6 to 256 kbps",
      "- {source: /live, mount: /live.opus, channels: 6}"                           => "must be 1 or 2",
      "- {source: /live, mount: /live.ogg, codec: vorbis}"                          => "must be opus or mp3",
      "- {source: /live, mount: /live.aac, codec: aac}"                             => "must be opus or mp3",
      "- {source: /live, mount: /live.mp3, codec: mp3, bitrate: 100}"               => "one of 8, 16,",
      "[{source: /live, mount: /x.opus}, {source: /other, mount: /x.opus}]"         => "more than one stream",
      "[{source: /a, mount: /b}, {source: /b, mount: /a}]"                          => "feeds back into itself",
      "[{source: /a, mount: /b}, {source: /b, mount: /c}, {source: /c, mount: /a}]" => "feeds back into itself",
      "- {source: /live, mount: /live.opus, quality: 10}"                           => "Invalid plugins.transcode",
      "- {mount: /live.opus}"                                                       => "Invalid plugins.transcode",
      "{source: /live, mount: /live.opus}"                                          => "Invalid plugins.transcode",
    }.each do |yaml, message|
      expect_raises(ArgumentError, message) { build_transcode(yaml) }
    end

    config = Config.new
    config.plugins = {"transcode" => streams("- {source: /live, mount: /live, bitrate: 64}")}
    expect_raises(ArgumentError, "can't transcode itself") { Lurcast::Plugins.validate!(config) }
  end

  it "encodes MP3, Vorbis and Opus input into one continuous Ogg Opus stream" do
    output = IO::Memory.new
    encoder = Transcode::OpusEncoder.new(64, 2)
    encoder.bitrate.should eq(64_000)
    writer = Transcode::OggOpusWriter.new(output, encoder.channels, encoder.pre_skip)
    begin
      # 3 s at 44.1 kHz stereo, then 1 s each of 48 kHz mono MP3, 44.1 kHz Vorbis and 48 kHz Opus.
      {"tone-44100-stereo.mp3" => "mp3", "tone-48000-mono.mp3" => "mp3", "tone.ogg" => "ogg", "tone.opus" => "ogg"}.each do |name, format|
        decoder = Transcode::Decoder.for(format).should_not be_nil
        decoded = 0
        transcode_fixture(name).each_slice(1000) do |chunk|
          decoder.decode(Slice.new(chunk.to_unsafe, chunk.size)) do |pcm, channels, rate|
            decoded += pcm.size // channels
            encoder.encode(pcm, channels, rate) { |packet| writer.write(packet) }
          end
        end
        decoder.close
        decoded.should be > 40_000
      end
      writer.flush
    ensure
      encoder.close
    end

    samples = verify_ogg_opus(ogg_pages(output.to_slice), 2)
    (samples.size // 2).should be_close(5.9 * 48_000, 0.2 * 48_000)
    rms(samples).should be_close(0.088, 0.02) # the fixtures are sine tones at 1/8 amplitude
  end

  it "mixes to mono and refuses what it can't decode" do
    output = IO::Memory.new
    encoder = Transcode::OpusEncoder.new(32, 1)
    writer = Transcode::OggOpusWriter.new(output, 1, encoder.pre_skip)
    decoder = Transcode::Decoder.for("mp3").should_not be_nil
    decoder.decode(transcode_fixture("tone-44100-stereo.mp3")) do |pcm, channels, rate|
      encoder.encode(pcm, channels, rate) { |packet| writer.write(packet) }
    end
    writer.flush
    encoder.close
    samples = verify_ogg_opus(ogg_pages(output.to_slice), 1)
    rms(samples).should be > 0.05

    Transcode::Decoder.for("aac").should be_nil
    Transcode::Decoder.for("webm").should be_nil
    Transcode::Decoder.supported?("audio/webm").should be_false
    flac = IO::Memory.new
    flac.write(ogg_page(0_u32, 0x02_u8, "\x7FFLAC\x01\x00".to_slice))
    flac.write(ogg_page(1_u32, 0_u8, Bytes.new(10)))
    expect_raises(Transcode::UnsupportedInput, "Ogg FLAC") do
      Transcode::OggDecoder.new.decode(flac.to_slice) { }
    end
  end

  it "publishes an Ogg Opus mount for a live MP3 source, with its titles, until the source leaves" do
    config = transcode_config("- {source: /live, mount: /live.opus, bitrate: 48}")
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    plugin = server.extensions.compact_map(&.as?(Transcode)).first
    spawn server.serve(http_listener)
    Fiber.yield

    source = connect_source(port, "/live", "audio/mpeg")
    done = Channel(Nil).new
    begin
      wait_until { server.get_mount("/live").try(&.has_source?) || false }
      set_title(port, "/live", "Artist - First")
      loop_audio(source, transcode_fixture("tone-44100-stereo.mp3"), done)

      wait_until(5.seconds) { !server.get_mount("/live.opus").nil? }
      target = server.get_mount("/live.opus").should_not be_nil
      target.content_type.should eq("audio/ogg")
      target.format.should eq("ogg")
      target.bitrate.should eq(48)
      target.station_details.name.should eq("Spec Radio")
      target.station_details.genre.should eq("Jazz")
      wait_until { target.current_song == "Artist - First" }

      listener = TCPSocket.new("127.0.0.1", port)
      listener.read_timeout = 5.seconds
      listener.print "GET /live.opus HTTP/1.0\r\n\r\n"
      head = read_head(listener)
      head.should start_with("HTTP/1.0 200")
      head.should contain("Content-Type: audio/ogg")
      received = IO::Memory.new
      buffer = Bytes.new(8192)
      sync = Ogg::Sync.new
      pages = [] of OggPageInfo
      until pages.size >= 8
        count = listener.read(buffer)
        raise "the listener stream ended" if count.zero?
        received.write(buffer[0, count])
        pages.concat(ogg_pages(buffer[0, count], sync))
      end
      listener.close
      samples = verify_ogg_opus(pages, 2)
      samples.size.should be > 48_000
      rms(samples).should be > 0.05

      set_title(port, "/live", "Artist - Second")
      wait_until { target.current_song == "Artist - Second" }

      # A changed entry restarts its transcoder with the new settings.
      config.plugins = {"transcode" => streams("- {source: /live, mount: /live.opus, bitrate: 32}")}
      plugin.config_reloaded(config)
      wait_until(5.seconds) { server.get_mount("/live.opus").try(&.bitrate) == 32 }
      wait_until { server.get_mount("/live.opus").try(&.current_song) == "Artist - Second" }

      # A source that reconnects within the grace period keeps the same target stream going.
      reloaded = server.get_mount("/live.opus").should_not be_nil
      done.close
      source.close
      wait_until { server.get_mount("/live").nil? }
      source = connect_source(port, "/live", "audio/mpeg")
      done = Channel(Nil).new
      loop_audio(source, transcode_fixture("tone-48000-mono.mp3"), done)
      sleep Transcode::Transcoder::GRACE + 500.milliseconds
      server.get_mount("/live.opus").should be(reloaded)
      reloaded.has_source?.should be_true
    ensure
      done.close
      source.close
    end

    wait_until(6.seconds) { server.get_mount("/live.opus").nil? }
  ensure
    server.try(&.stop)
  end

  it "doesn't publish a target for a source it can't decode" do
    config = transcode_config("- {source: /video, mount: /video.opus}")
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    Fiber.yield

    source = connect_source(port, "/video", "video/webm")
    begin
      20.times do
        source.write(Bytes.new(200, 7_u8))
        source.flush
        sleep 25.milliseconds
      end
      wait_until { server.get_mount("/video").try(&.has_source?) || false }
      sleep 600.milliseconds
      server.get_mount("/video.opus").should be_nil
    ensure
      source.close
    end
  ensure
    server.try(&.stop)
  end

  it "encodes MP3 that ffmpeg decodes, from MP3, Vorbis and Opus" do
    encoder = Transcode::Encoder.for("mp3", 128, 2)
    output = IO::Memory.new
    writer = encoder.writer(output)
    {"tone-44100-stereo.mp3" => "mp3", "tone.ogg" => "ogg", "tone.opus" => "ogg"}.each do |name, format|
      decoder = Transcode::Decoder.for(format).should_not be_nil
      transcode_fixture(name).each_slice(1000) do |chunk|
        decoder.decode(Slice.new(chunk.to_unsafe, chunk.size)) do |pcm, channels, rate|
          encoder.encode(pcm, channels, rate) { |packet| writer.write(packet) }
        end
      end
      decoder.close
    end
    encoder.close
    MP3.parse_frame(output.to_slice).try(&.bitrate_kbps).should eq(128)

    path = File.tempname("transcode", ".mp3")
    File.write(path, output.to_slice)
    begin
      errors = IO::Memory.new
      probe = IO::Memory.new
      Process.run("ffmpeg", ["-v", "error", "-i", path, "-f", "null", "-"], error: errors).success?.should be_true
      errors.to_s.should eq("")
      Process.run("ffprobe", ["-v", "error", "-show_entries", "stream=codec_name,sample_rate,channels:format=duration", "-of", "csv=p=0", path], output: probe)
      lines = probe.to_s.lines
      lines[0].should eq("mp3,44100,2")
      # 3 s of MP3, then 1 s each of Vorbis and Opus.
      lines[1].to_f.should be_close(5.0, 0.2)
    ensure
      File.delete(path)
    end
  end

  it "publishes an MP3 mount for a live Ogg Opus source" do
    config = transcode_config("- {source: /opus, mount: /opus.mp3, codec: mp3, bitrate: 64}")
    http_listener = TCPServer.new("127.0.0.1", 0)
    port = http_listener.local_address.as(Socket::IPAddress).port
    server = IcecastServer.new(config)
    spawn server.serve(http_listener)
    Fiber.yield

    source = connect_source(port, "/opus", "audio/ogg")
    done = Channel(Nil).new
    begin
      loop_audio(source, File.read(File.join(__DIR__, "..", "fixtures", "hls", "tone.opus")).to_slice, done)
      wait_until(5.seconds) { !server.get_mount("/opus.mp3").nil? }
      target = server.get_mount("/opus.mp3").should_not be_nil
      target.content_type.should eq("audio/mpeg")
      target.format.should eq("mp3")
      wait_until(5.seconds) { target.mp3_info.try(&.bitrate_kbps) == 64 }
      info = target.mp3_info.should_not be_nil
      info.channels.should eq(2)
    ensure
      done.close
      source.close
    end
  ensure
    server.try(&.stop)
  end
end
