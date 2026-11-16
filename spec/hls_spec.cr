require "./spec_helper"

private PREFIX = "/_lurcast/hls/live/"

# MPEG-1 Layer III, 128 kbps, no padding: 1152 samples per frame.
private def mp3_frames(count : Int32, sample_rate_byte : UInt8 = 0x90_u8, size : Int32 = 417) : Bytes
  io = IO::Memory.new
  count.times do
    frame = Bytes.new(size)
    frame[0] = 0xff_u8
    frame[1] = 0xfb_u8
    frame[2] = sample_rate_byte
    frame[3] = 0x64_u8
    io.write(frame)
  end
  io.to_slice
end

# 48 kHz variant of the same header (sample-rate index 1, 384-byte frames).
private def mp3_48k_frames(count : Int32) : Bytes
  mp3_frames(count, 0x94_u8, 384)
end

# ADTS, no CRC, MPEG-4 AAC LC, 44.1 kHz, 2 channels: 1024 samples per frame.
private def adts_frames(count : Int32, length : Int32 = 200) : Bytes
  io = IO::Memory.new
  count.times do
    frame = Bytes.new(length)
    frame[0] = 0xff_u8
    frame[1] = 0xf1_u8
    frame[2] = 0x50_u8
    frame[3] = (0x80 | ((length >> 11) & 0x03)).to_u8
    frame[4] = ((length >> 3) & 0xff).to_u8
    frame[5] = (((length & 0x07) << 5) | 0x1f).to_u8
    frame[6] = 0xfc_u8
    io.write(frame)
  end
  io.to_slice
end

private def segment!(segmenter : HLS::Segmenter, sequence : Int64) : Bytes
  segmenter.segment(sequence) || raise "missing segment #{sequence}"
end

private def playlist!(segmenter : HLS::Segmenter) : String
  segmenter.playlist(PREFIX) || raise "missing playlist"
end

private def syncsafe(bytes : Bytes, offset : Int32) : Int32
  (0..3).reduce(0) { |acc, i| (acc << 7) | bytes[offset + i].to_i }
end

# Parses the ID3v2.4 tag at the start of a segment into {frame id => body}.
private def id3_frames(bytes : Bytes) : Hash(String, Bytes)
  String.new(bytes[0, 3]).should eq("ID3")
  bytes[3].should eq(4)
  tag_end = 10 + syncsafe(bytes, 6)
  frames = {} of String => Bytes
  offset = 10
  while offset < tag_end
    id = String.new(bytes[offset, 4])
    size = syncsafe(bytes, offset + 4)
    frames[id] = bytes[offset + 10, size]
    offset += 10 + size
  end
  frames
end

private def timestamp(bytes : Bytes) : Int64
  priv = id3_frames(bytes)["PRIV"]
  owner = "com.apple.streaming.transportStreamTimestamp"
  String.new(priv[0, owner.size]).should eq(owner)
  priv[owner.size].should eq(0)
  IO::ByteFormat::BigEndian.decode(UInt64, priv[owner.size + 1, 8]).to_i64
end

private def extinfs(playlist : String) : Array(Float64)
  playlist.lines.select(&.starts_with?("#EXTINF:")).map(&.lchop("#EXTINF:").rchop(",").to_f)
end

describe HLS::Segmenter do
  # 1 s target at 1152/44100 s per frame: 39 frames (1.019 s) per segment.
  it "has no playlist before the first full segment" do
    segmenter = HLS::Segmenter.new(:mp3, 1.0, first_sequence: 100_i64)
    segmenter.write(mp3_frames(38))
    segmenter.playlist(PREFIX).should be_nil
    segmenter.segment(100_i64).should be_nil
    segmenter.bytesize.should be > 38 * 417

    segmenter.write(mp3_frames(1))
    playlist!(segmenter).should eq(<<-M3U)
      #EXTM3U
      #EXT-X-VERSION:3
      #EXT-X-TARGETDURATION:2
      #EXT-X-MEDIA-SEQUENCE:100
      #EXTINF:1.019,
      /_lurcast/hls/live/100.mp3

      M3U
  end

  it "cuts segments on frame boundaries at or after the target" do
    segmenter = HLS::Segmenter.new(:mp3, 1.0, first_sequence: 1_i64)
    segmenter.write(mp3_frames(39 * 3 + 5))
    durations = extinfs(playlist!(segmenter))
    durations.size.should eq(3)
    durations.each { |duration| duration.should be_close(39 * 1152 / 44_100, 0.001) }

    data = segment!(segmenter, 2_i64)
    tag_size = 10 + syncsafe(data, 6)
    (data.size - tag_size).should eq(39 * 417)
    data[tag_size].should eq(0xff)
  end

  it "trims the window and advances the media sequence" do
    segmenter = HLS::Segmenter.new(:mp3, 1.0, 3, first_sequence: 10_i64)
    segmenter.write(mp3_frames(39 * 5))
    playlist = playlist!(segmenter)
    playlist.should contain("#EXT-X-MEDIA-SEQUENCE:12\n")
    playlist.lines.select(&.starts_with?(PREFIX)).should eq(["#{PREFIX}12.mp3", "#{PREFIX}13.mp3", "#{PREFIX}14.mp3"])
    segmenter.segment(11_i64).should be_nil
    segmenter.segment(14_i64).should_not be_nil
    segmenter.segment(15_i64).should be_nil
  end

  it "prefixes segments with an ID3 PRIV transport stream timestamp" do
    segmenter = HLS::Segmenter.new(:mp3, 1.0, first_sequence: 0_i64)
    segmenter.write(mp3_frames(39 * 3))
    timestamp(segment!(segmenter, 0_i64)).should eq(0)
    timestamp(segment!(segmenter, 1_i64)).should eq(39_i64 * 1152 * 90_000 // 44_100)
    timestamp(segment!(segmenter, 2_i64)).should eq(78_i64 * 1152 * 90_000 // 44_100)
  end

  it "stores the title in TIT2 only when present" do
    segmenter = HLS::Segmenter.new(:mp3, 1.0, first_sequence: 0_i64)
    segmenter.write(mp3_frames(39), "Artist - Sång\0")
    segmenter.write(mp3_frames(39))

    titled = id3_frames(segment!(segmenter, 0_i64))
    tit2 = titled["TIT2"]
    tit2[0].should eq(3)
    String.new(tit2[1..]).should eq("Artist - Sång")
    id3_frames(segment!(segmenter, 1_i64)).has_key?("TIT2").should be_false
  end

  it "cuts with a discontinuity when the sample rate changes" do
    segmenter = HLS::Segmenter.new(:mp3, 1.0, first_sequence: 0_i64)
    segmenter.write(mp3_frames(20))
    segmenter.write(mp3_48k_frames(42))

    playlist = playlist!(segmenter)
    durations = extinfs(playlist)
    durations.size.should eq(2)
    durations[0].should be_close(20 * 1152 / 44_100, 0.001)
    durations[1].should be_close(42 * 1152 / 48_000, 0.001)
    playlist.should contain("#EXT-X-DISCONTINUITY\n#EXTINF:1.008,\n#{PREFIX}1.mp3\n")
    timestamp(segment!(segmenter, 1_i64)).should eq(20_i64 * 1152 * 90_000 // 44_100)
  end

  it "segments ADTS AAC" do
    segmenter = HLS::Segmenter.new(:aac, 1.0, first_sequence: 5_i64)
    segmenter.extension.should eq("aac")
    segmenter.content_type.should eq("audio/aac")
    # 1 s at 1024/44100 s per frame: 44 frames (1.022 s).
    segmenter.write(adts_frames(44 * 2))

    playlist = playlist!(segmenter)
    playlist.should contain("#EXTINF:1.022,\n#{PREFIX}5.aac\n")
    timestamp(segment!(segmenter, 6_i64)).should eq(44_i64 * 1024 * 90_000 // 44_100)
  end

  it "reports MP3 extension and content type" do
    segmenter = HLS::Segmenter.new(:mp3)
    segmenter.extension.should eq("mp3")
    segmenter.content_type.should eq("audio/mpeg")
  end

  it "drops garbage and truncated frames without raising" do
    segmenter = HLS::Segmenter.new(:mp3, 1.0, first_sequence: 0_i64)
    segmenter.write(Bytes.new(1000) { |i| (i * 37 % 256).to_u8 })
    segmenter.write(Bytes.empty)
    segmenter.write(mp3_frames(1)[0, 200])
    segmenter.write(Bytes[0xff, 0xfb])
    segmenter.bytesize.should eq(0)

    aac = HLS::Segmenter.new(:aac, 1.0, first_sequence: 0_i64)
    aac.write(mp3_frames(5))
    aac.write(Bytes[0x56, 0xe0, 0x10, 0, 0, 0, 0])
    aac.write(adts_frames(1)[0, 50])
    aac.bytesize.should eq(0)

    segmenter.write(mp3_frames(39))
    segmenter.playlist(PREFIX).should_not be_nil
  end
end

private HLS_FIXTURES = "#{__DIR__}/fixtures"

# Feeds a fixture to a segmenter in chunks of whole frames or arbitrary bytes, as the mount would.
private def segment_file(segmenter : HLS::Segmenter, path : String, chunk = 1000) : Nil
  bytes = File.read("#{HLS_FIXTURES}/#{path}").to_slice
  offset = 0
  while offset < bytes.size
    size = Math.min(chunk, bytes.size - offset)
    segmenter.write(bytes[offset, size])
    offset += size
  end
end

private def mount_frames(path : String, content_type : String) : Bytes
  mount = MountPoint.new("/hls", 1 << 20, 1 << 21)
  mount.apply_headers(HTTP::Headers{"Content-Type" => content_type})
  output = IO::Memory.new
  tap = SpecCollectTap.new(output)
  mount.add_tap(tap)
  bytes = File.read("#{HLS_FIXTURES}/#{path}").to_slice
  bytes.each_slice(997) { |slice| mount.publish(Bytes.new(slice.to_unsafe, slice.size)) }
  output.to_slice
end

# Feeds a fixture through a mount to *segmenter*, as the HLS plugin's tap does: the segmenter gets
# the mount's own (reused) buffer.
private def segment_through_mount(segmenter : HLS::Segmenter, path : String, content_type : String) : Nil
  mount = MountPoint.new("/hls", 1 << 16, 1 << 17)
  mount.apply_headers(HTTP::Headers{"Content-Type" => content_type})
  mount.add_tap(SpecSegmenterTap.new(segmenter))
  File.read("#{HLS_FIXTURES}/#{path}").to_slice.each_slice(997) { |slice| mount.publish(Bytes.new(slice.to_unsafe, slice.size)) }
end

private class SpecSegmenterTap < AudioTap
  def initialize(@segmenter : HLS::Segmenter)
  end

  def receive(data : Bytes) : Nil
    @segmenter.write(data)
  end
end

private class SpecCollectTap < AudioTap
  def initialize(@io : IO)
  end

  def receive(data : Bytes) : Nil
    @io.write(data)
  end
end

# Joins the playlist's init segment and segments into one file and decodes it with ffmpeg; returns
# the decoded duration in seconds.
private def decode_playlist(segmenter : HLS::Segmenter) : Float64
  playlist = playlist!(segmenter)
  file = IO::Memory.new
  playlist.each_line do |line|
    if map = line.match(/^#EXT-X-MAP:URI=".*init-(\d+)\.mp4"/)
      file.write(segmenter.init(map[1].to_i) || raise "missing init")
    elsif line.starts_with?(PREFIX)
      file.write(segment!(segmenter, line.lchop(PREFIX).split('.').first.to_i64))
    end
  end
  path = File.tempname("hls", segmenter.container.fmp4? ? ".mp4" : ".#{segmenter.extension}")
  File.write(path, file.to_slice)
  errors = IO::Memory.new
  output = IO::Memory.new
  Process.run("ffmpeg", ["-v", "error", "-i", path, "-f", "null", "-"], error: errors).success?.should be_true
  errors.to_s.should eq("")
  Process.run("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path], output: output)
  output.to_s.strip.to_f
ensure
  File.delete(path) if path && File.exists?(path)
end

describe "HLS framers" do
  it "rewrites LATM as ADTS for packed audio" do
    segmenter = HLS::Segmenter.new(HLS::AACFramer.new, HLS::Container::Packed, 1.0, 10, first_sequence: 0_i64)
    segmenter.write(mount_frames("hls/tone.latm", "audio/aac"))
    segmenter.codecs.should eq("mp4a.40.2")
    data = segment!(segmenter, 0_i64)
    tag_size = 10 + syncsafe(data, 6)
    AAC.parse_header(data[tag_size..]).try(&.transport).should eq(AAC::Transport::ADTS)
    decode_playlist(segmenter).should be_close(3.0, 0.2)
  end

  it "puts AAC in fMP4" do
    segmenter = HLS::Segmenter.new(HLS::AACFramer.new, HLS::Container::FMP4, 1.0, 10, first_sequence: 0_i64)
    segment_through_mount(segmenter, "hls/tone.aac", "audio/aac")
    playlist!(segmenter).should contain("#EXT-X-MAP:URI=\"#{PREFIX}init-1.mp4\"\n")
    playlist!(segmenter).should contain("#{PREFIX}0.m4s\n")
    decode_playlist(segmenter).should be_close(3.0, 0.2)
  end

  it "puts Ogg Opus in fMP4" do
    segmenter = HLS::Segmenter.new(HLS::OggFramer.new, HLS::Container::FMP4, 1.0, 10, first_sequence: 0_i64)
    segment_file(segmenter, "hls/tone.opus")
    segmenter.codecs.should eq("opus")
    # 20 ms packets: the last segment ends exactly at 4 s.
    decode_playlist(segmenter).should be_close(4.0, 0.05)
  end

  it "puts Ogg FLAC and native FLAC in fMP4" do
    {HLS::OggFramer.new => "join/tone.oga", HLS::FLACFramer.new => "join/tone.flac"}.each do |framer, file|
      segmenter = HLS::Segmenter.new(framer, HLS::Container::FMP4, 1.0, 10, first_sequence: 0_i64)
      segment_file(segmenter, file)
      segmenter.codecs.should eq("fLaC")
      decode_playlist(segmenter).should be_close(2.0, 0.2)
    end
  end

  it "reads FLAC as the mount publishes it" do
    segmenter = HLS::Segmenter.new(HLS::FLACFramer.new, HLS::Container::FMP4, 1.0, 10, first_sequence: 0_i64)
    segmenter.write(mount_frames("join/tone.flac", "audio/flac"))
    decode_playlist(segmenter).should be_close(2.0, 0.2)
  end

  it "says why Ogg Vorbis can't be served" do
    segmenter = HLS::Segmenter.new(HLS::OggFramer.new, HLS::Container::FMP4, 1.0, 10, first_sequence: 0_i64)
    segment_file(segmenter, "transcode/tone.ogg")
    segmenter.unsupported.should eq("Ogg Vorbis can't be served over HLS")
    segmenter.playlist(PREFIX).should be_nil
  end
end

describe "Low-latency HLS" do
  it "publishes partial segments that make up each segment" do
    segmenter = HLS::Segmenter.new(HLS::AACFramer.new, HLS::Container::FMP4, 2.0, 10, part_seconds: 0.5, first_sequence: 0_i64)
    segmenter.write(mount_frames("hls/tone.aac", "audio/aac"))
    playlist = playlist!(segmenter)
    playlist.should contain("#EXT-X-PART-INF:PART-TARGET=0.500\n")
    playlist.should contain("#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.500\n")
    playlist.should match(/#EXT-X-PRELOAD-HINT:TYPE=PART,URI="#{PREFIX}\d+\.\d+\.m4s"\n\z/)
    # Segments end on part boundaries: 4 parts of 21 frames (84 × 1024 / 44100 s).
    playlist.should contain("#EXTINF:1.950,\n")
    parts = playlist.lines.select(&.starts_with?("#EXT-X-PART:"))
    parts.should_not be_empty
    parts.each do |line|
      line.match(/DURATION=([\d.]+)/).try(&.[1].to_f).should_not be_nil
      (line.match(/DURATION=([\d.]+)/).try(&.[1].to_f) || 1.0).should be <= 0.5
    end

    joined = IO::Memory.new
    index = 0
    while part = segmenter.part(0_i64, index)
      joined.write(part)
      index += 1
    end
    joined.to_slice.should eq(segment!(segmenter, 0_i64))
    decode_playlist(segmenter).should be_close(3.9, 0.1)
  end

  it "blocks a playlist reload until the part exists" do
    segmenter = HLS::Segmenter.new(HLS::AACFramer.new, HLS::Container::FMP4, 2.0, 10, part_seconds: 0.5, first_sequence: 0_i64)
    bytes = mount_frames("hls/tone.aac", "audio/aac")
    segmenter.wait_for(0_i64, 0, 50.milliseconds).should be_false
    done = Channel(Bool).new
    spawn { done.send(segmenter.wait_for(0_i64, 1, 2.seconds)) }
    Fiber.yield
    segmenter.write(bytes)
    receive(done).should be_true
    segmenter.wait_for(0_i64).should be_true
  end
end
