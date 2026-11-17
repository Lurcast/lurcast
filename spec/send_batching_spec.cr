require "./spec_helper"

private class SpecCountingTap < AudioTap
  getter sizes = [] of Int32

  def receive(data : Bytes) : Nil
    @sizes << data.size
  end
end

private def batched_mount(interval : Time::Span, burst = 4096, queue = 524_288) : {MountPoint, SpecCountingTap}
  mount = MountPoint.new("/batch", burst, queue, send_interval: interval)
  mount.apply_headers(HTTP::Headers{"Content-Type" => "audio/mpeg"})
  mount.connect_source(IO::Memory.new, SourceProtocol::Icecast)
  tap = SpecCountingTap.new
  mount.add_tap(tap)
  {mount, tap}
end

describe "Send batching" do
  it "holds the source's audio, then sends it on in one piece when the interval is up" do
    mount, tap = batched_mount(150.milliseconds)
    listener = IO::Memory.new
    mount.add_listener(listener, "127.0.0.1", false)
    5.times { mount.publish(mp3_frame) }

    tap.sizes.should be_empty
    mount.initial_burst.should be_empty
    # Nothing more comes from the source: the batch still goes out once it is due.
    wait_until { listener.size == 5 * 417 }
    tap.sizes.should eq([5 * 417])
  ensure
    mount.try(&.remove_listener(listener)) if listener
  end

  it "sends a batch early once it holds a quarter of the listener queue" do
    mount, tap = batched_mount(1.hour, queue: 16_384)
    9.times { mount.publish(mp3_frame) }
    tap.sizes.should be_empty
    mount.publish(mp3_frame) # 4170 bytes, over 16384 / 4
    tap.sizes.should eq([10 * 417])
  end

  it "sends what it holds when the source leaves" do
    mount, tap = batched_mount(1.hour)
    3.times { mount.publish(mp3_frame) }
    tap.sizes.should be_empty
    mount.disconnect_source
    tap.sizes.should eq([3 * 417])
    mount.initial_burst.size.should eq(3 * 417)
  end

  it "sends each piece as it comes with no interval" do
    mount, tap = batched_mount(Time::Span.zero)
    3.times { mount.publish(mp3_frame + mp3_frame) }
    tap.sizes.sum.should eq(6 * 417)
    tap.sizes.size.should eq(3)
  end
end

describe MountPoint::ListenerQueue do
  it "drains queued packets in order while they fit" do
    queue = MountPoint::ListenerQueue.new(1024)
    queue.enqueue(Bytes[1, 2])
    queue.enqueue(Bytes[3, 4, 5])
    queue.enqueue(Bytes[6, 7, 8, 9])
    output = IO::Memory.new

    queue.drain(output, 6).should eq(5)
    output.to_slice.should eq(Bytes[1, 2, 3, 4, 5])
    queue.bytesize.should eq(4)
    queue.receive?.should eq(Bytes[6, 7, 8, 9])
  end
end

describe Config do
  it "checks send_interval_ms" do
    config = Config.new
    config.send_interval_for("/live").should eq(250.milliseconds)
    config.send_interval_ms = 0
    config.validate!
    config.send_interval_ms = 2001
    expect_raises(ArgumentError, /send_interval_ms must be between 0 and 2000/) { config.validate! }

    config.send_interval_ms = 250
    mount = MountConfig.new(send_interval_ms: 40)
    config.validate_mount_settings!("/talk", mount)
    config.mounts = {"/talk" => mount}
    config.send_interval_for("/talk").should eq(40.milliseconds)
    expect_raises(ArgumentError, /mount \/talk send_interval_ms must be between 0 and 2000/) do
      config.validate_mount_settings!("/talk", MountConfig.new(send_interval_ms: -1))
    end
  end
end
