require "spec"
require "../src/hls"

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
