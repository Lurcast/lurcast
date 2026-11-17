require "./spec_helper"
require "../src/pacer"

describe Pacer do
  it "counts each wait from the start, so oversleeping doesn't add up" do
    start = Time.instant
    pacer = Pacer.new(1000.0, start) # 1000 bytes a second

    pacer.sent(250, start).should eq(250.milliseconds)
    # Woke 20 ms late: the next chunk is still due at 500 ms, so it waits less.
    pacer.sent(250, start + 270.milliseconds).should eq(230.milliseconds)
    # Sending took longer than the chunk plays: no wait, and the time isn't lost.
    pacer.sent(250, start + 800.milliseconds).should eq(Time::Span.zero)
    pacer.sent(250, start + 900.milliseconds).should eq(100.milliseconds)
  end

  it "starts again from now after falling more than a second behind" do
    start = Time.instant
    pacer = Pacer.new(1000.0, start)

    pacer.sent(100, start + 5.seconds).should eq(Time::Span.zero)
    pacer.sent(100, start + 5.seconds).should eq(100.milliseconds)
  end

  it "starts again from now after a pause" do
    start = Time.instant
    pacer = Pacer.new(1000.0, start)
    pacer.sent(500, start)

    pacer.restart(start + 400.milliseconds)
    pacer.sent(100, start + 400.milliseconds).should eq(100.milliseconds)
  end
end
