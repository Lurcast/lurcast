require "./spec_helper"

private FIXTURES = "#{__DIR__}/fixtures/join"

# Feeds *file* to a mount in small chunks, as a source would send it.
private def publish_file(mount : MountPoint, file : String, chunk = 700, upto : Int32? = nil) : Bytes
  bytes = File.read("#{FIXTURES}/#{file}").to_slice
  limit = upto || bytes.size
  offset = 0
  while offset < limit
    size = Math.min(chunk, limit - offset)
    mount.publish(bytes[offset, size])
    offset += size
  end
  bytes
end

private def mount_for(content_type : String, burst = 8192) : MountPoint
  mount = MountPoint.new("/join", burst, burst * 8)
  mount.apply_headers(HTTP::Headers{"Content-Type" => content_type})
  mount.connect_source(IO::Memory.new, SourceProtocol::Icecast)
  mount
end

# Decodes *bytes* with ffmpeg and returns how many frames it decoded; fails on any decoding error.
private def decoded_frames(bytes : Bytes, extension : String) : Int32
  path = File.tempname("join", ".#{extension}")
  File.write(path, bytes)
  output = IO::Memory.new
  errors = IO::Memory.new
  status = Process.run("ffmpeg", ["-v", "error", "-i", path, "-map", "0", "-f", "framemd5", "-"], output: output, error: errors)
  status.success?.should be_true
  errors.to_s.should eq("")
  output.to_s.lines.count { |line| !line.starts_with?('#') }
ensure
  File.delete(path) if path && File.exists?(path)
end

private def join_header(mount : MountPoint) : Bytes
  mount.@join.should_not(be_nil).try(&.header).should_not be_nil
end

private def bytes_start_with?(bytes : Bytes, prefix : Bytes) : Bool
  bytes.size >= prefix.size && bytes[0, prefix.size] == prefix
end

describe "Late-joining listeners" do
  it "get a native FLAC stream's headers, then audio from a frame" do
    mount = mount_for("audio/flac")
    bytes = publish_file(mount, "tone.flac")
    burst = mount.initial_burst
    header = join_header(mount)

    bytes_start_with?(bytes, header).should be_true
    bytes_start_with?(burst, header).should be_true
    burst.size.should be < bytes.size
    FLAC.frame_header(burst[header.size..]).should_not be_nil
    decoded_frames(burst, "flac").should be > 3
    mount.format.should eq("flac")
  end

  it "get every header packet of Ogg FLAC" do
    # ffmpeg writes pages of about 8 KB, so the burst must hold one whole.
    mount = mount_for("audio/ogg", burst: 20_000)
    file = File.read("#{FIXTURES}/tone.oga").to_slice
    # Leave out the end-of-stream page: a live stream hasn't ended.
    last_page = (0..file.size - 4).reverse_each.find! { |index| file[index, 4] == "OggS".to_slice }
    bytes = publish_file(mount, "tone.oga", upto: last_page)
    burst = mount.initial_burst

    # The STREAMINFO packet's page and the Vorbis comment page.
    burst.size.should be < bytes.size
    String.new(burst[28, 5]).should eq("\u007FFLAC")
    decoded_frames(burst, "oga").should be > 3
  end

  it "get WebM headers and a cluster made for them in the middle of one" do
    mount = mount_for("audio/webm", burst: 4096)
    bytes = publish_file(mount, "tone.webm")
    burst = mount.initial_burst
    header = join_header(mount)

    bytes_start_with?(bytes, header).should be_true
    bytes_start_with?(burst, header).should be_true
    burst.size.should be < bytes.size
    burst[header.size, 4].should eq(Bytes[0x1F, 0x43, 0xB6, 0x75])
    decoded_frames(burst, "webm").should be > 10
    mount.format.should eq("webm")
  end

  it "start WebM video on a keyframe" do
    # One keyframe a second, about 8 KB apart.
    mount = mount_for("video/webm", burst: 16_384)
    publish_file(mount, "clip.webm")
    burst = mount.initial_burst

    decoded_frames(burst, "webm").should be > 5
  end

  it "wait for the next join point when the buffer has none" do
    # Keyframes are a second (about 8 KB) apart, so with a 4 KB burst the buffer just before the
    # second one holds none.
    mount = mount_for("video/webm", burst: 4096)
    bytes = File.read("#{FIXTURES}/clip.webm").to_slice
    header = Matroska::Join.new(1 << 20).tap(&.feed(bytes)).header.should_not be_nil
    publish_file(mount, "clip.webm", upto: 7900)
    listener = IO::Memory.new
    mount.add_listener(listener, "127.0.0.1", false)
    wait_until { listener.size >= header.size }
    listener.to_slice.should eq(header)

    offset = 7900
    while offset < bytes.size
      size = Math.min(500, bytes.size - offset)
      mount.publish(bytes[offset, size])
      offset += size
    end
    wait_until { listener.size > header.size + 1000 }
    received = listener.to_slice.dup
    received[header.size, 4].should eq(Bytes[0x1F, 0x43, 0xB6, 0x75])
    decoded_frames(received, "webm").should be > 10
    received.size.should eq(header.size + bytes.size - 8039)
  ensure
    mount.try(&.remove_listener(listener)) if listener
  end

  it "replaces the headers when the source starts again" do
    mount = mount_for("audio/webm", burst: 4096)
    publish_file(mount, "tone.webm", upto: 6000)
    mount.connect_source(IO::Memory.new, SourceProtocol::Icecast)
    bytes = publish_file(mount, "tone.webm")
    header = join_header(mount)
    bytes_start_with?(bytes, header).should be_true
    decoded_frames(mount.initial_burst, "webm").should be > 10
  end
end
