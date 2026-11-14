require "./decoders"
require "./encoder"

class Lurcast::Plugins::Transcode < Lurcast::Plugin
  # A new source connection on the source mount, queued before its audio so the worker starts a
  # fresh decoder for it.
  record Connection, format : String, mount : String

  alias QueueItem = Bytes | Connection

  # Copies what the source mount publishes into the transcoder's queue. It runs under the mount's
  # broadcast lock, so it never waits: when the queue is full the chunk is dropped.
  class Tap < AudioTap
    def initialize(@queue : Channel(QueueItem), @mount : String)
    end

    def receive(data : Bytes) : Nil
      return if data.empty?
      select
      when @queue.send(data.dup)
      else
        Log.debug { "Transcode queue for #{@mount} is full; dropped #{data.size} bytes" }
      end
    rescue Channel::ClosedError
    end
  end

  # The target mount, fed through a pipe: the server reads the pipe as an internal source, and the
  # worker writes Ogg pages into it.
  class Output
    @reader : IO
    @writer : IO
    @served = Channel(Nil).new

    def initialize(@server : IcecastServer, @mount : String, headers : HTTP::Headers, channels : Int32, pre_skip : Int32)
      @reader, @writer = IO.pipe
      @ogg = OggOpusWriter.new(@writer, channels, pre_skip)
      reader = @reader
      spawn(name: "transcode #{@mount}") do
        unless @server.serve_source(@mount, reader, headers)
          Log.warn { "Transcode can't publish #{@mount}: the mount already has a source" }
        end
      ensure
        reader.close rescue nil
        @served.close
      end
    end

    def write(packet : Bytes) : Nil
      @ogg.write(packet)
    end

    # The target mount while this output is its source.
    def mount_point : MountPoint?
      @server.get_mount(@mount).try { |point| point if point.source.same?(@reader) }
    end

    # Ends the stream and waits a moment for the server to release the target mount.
    def close : Nil
      @ogg.flush rescue nil
      @writer.close rescue nil
      select
      when @served.receive?
      when timeout(1.second)
      end
    end
  end

  # Transcodes one configured entry. A supervisor fiber watches the source mount: while it has a
  # source, a tap feeds a worker fiber that decodes, re-encodes and publishes the target mount. When
  # the source has been gone for `GRACE`, the worker stops and the target mount goes away.
  class Transcoder
    POLL        = 250.milliseconds
    GRACE       = 2.seconds
    QUEUE_SIZE  = 256
    RETRY_AFTER = 5.seconds

    getter entry : Entry

    @mutex = Mutex.new
    @stopped = Atomic(Bool).new(false)
    @wake = Channel(Nil).new(1)
    @title = ""
    @output : Output?
    @details : MountPoint::StationDetails?
    # The source mount and connection being tapped, the tap, and the worker's queue.
    @tapped : MountPoint?
    @tapped_source : IO?
    @tap : Tap?
    @queue : Channel(QueueItem)?
    @worker_done : Channel(Nil)?
    @finished = Channel(Nil).new

    def initialize(@server : IcecastServer, @entry : Entry)
    end

    def start : Nil
      spawn(name: "transcode supervisor #{@entry.mount}") { supervise }
    end

    def stop : Nil
      return if @stopped.swap(true)
      select
      when @wake.send(nil)
      else
      end
    end

    # Waits until the transcoder has stopped and unpublished its target, at most *limit*.
    def wait(limit : Time::Span) : Nil
      select
      when @finished.receive?
      when timeout(limit)
      end
    end

    def title=(song : String) : Nil
      output = @mutex.synchronize do
        @title = song
        @output
      end
      output.try(&.mount_point).try(&.update_metadata(song))
    end

    private def supervise : Nil
      last_seen = Time.instant
      until @stopped.get
        point = @server.get_mount(@entry.source)
        source = point.try(&.source)
        if point && source && point.has_source?
          last_seen = Time.instant
          attach(point, source) unless point.same?(@tapped) && source.same?(@tapped_source)
        elsif @queue && Time.instant - last_seen >= GRACE
          detach
        end
        select
        when @wake.receive
        when timeout(POLL)
        end
      end
    rescue ex
      Log.error(exception: ex) { "Transcode supervisor for #{@entry.mount} failed" }
    ensure
      detach
      @finished.close
    end

    private def attach(point : MountPoint, source : IO) : Nil
      untap
      @tapped = point
      @tapped_source = source
      @mutex.synchronize { @details = point.station_details }
      format = point.format
      unless Decoder.supported?(format)
        Log.warn { "Transcode can't read #{@entry.source}: #{format} streams can't be transcoded" }
        stop_worker
        return
      end
      @queue = nil if @queue.try(&.closed?)
      queue = @queue || start_worker
      queue.send(Connection.new(point.format, @entry.source))
      self.title = point.current_song unless point.current_song.empty?
      tap = Tap.new(queue, @entry.source)
      point.add_tap(tap, burst: true)
      @tap = tap
    rescue Channel::ClosedError
      @queue = nil
    end

    private def untap : Nil
      if (tap = @tap) && (point = @tapped)
        point.remove_tap(tap)
      end
      @tap = nil
      @tapped = nil
      @tapped_source = nil
    end

    # Removes the tap and ends the worker, which unpublishes the target mount.
    private def detach : Nil
      untap
      stop_worker
    end

    private def stop_worker : Nil
      @queue.try(&.close)
      @queue = nil
      if done = @worker_done
        select
        when done.receive?
        when timeout(2.seconds)
        end
      end
      @worker_done = nil
    end

    private def start_worker : Channel(QueueItem)
      queue = Channel(QueueItem).new(QUEUE_SIZE)
      done = Channel(Nil).new
      @queue = queue
      @worker_done = done
      spawn(name: "transcode #{@entry.mount}") { work(queue, done) }
      queue
    end

    private def work(queue : Channel(QueueItem), done : Channel(Nil)) : Nil
      encoder = OpusEncoder.new(@entry.bitrate, @entry.channels)
      decoder = nil.as(Decoder?)
      retry_at = nil.as(Time::Instant?)
      title_applied = false
      while item = queue.receive?
        case item
        in Connection
          decoder.try(&.close)
          decoder = Decoder.for(item.format)
          unless decoder
            Log.warn { "Transcode can't read #{item.mount}: #{item.format} streams can't be transcoded" }
            close_output
          end
        in Bytes
          active = decoder || next
          begin
            active.decode(item) do |pcm, channels, rate|
              encoder.encode(pcm, channels, rate) do |packet|
                next if retry_at && Time.instant < retry_at
                output = @mutex.synchronize { @output } || open_output(encoder)
                begin
                  output.write(packet)
                  retry_at = nil
                  title_applied = apply_title(output) unless title_applied
                rescue IO::Error
                  close_output
                  title_applied = false
                  retry_at = Time.instant + RETRY_AFTER
                end
              end
            end
          rescue ex : UnsupportedInput
            Log.warn { "Transcode can't read #{@entry.source}: #{ex.message}" }
            active.close
            decoder = nil
            close_output
            title_applied = false
          end
        end
      end
    rescue ex
      Log.error(exception: ex) { "Transcode worker for #{@entry.mount} failed" }
    ensure
      queue.close
      decoder.try(&.close)
      encoder.try(&.close)
      close_output
      done.close
    end

    private def open_output(encoder : OpusEncoder) : Output
      details = @mutex.synchronize { @details }
      headers = HTTP::Headers{"Content-Type" => "audio/ogg", "Icy-Br" => @entry.bitrate.to_s}
      if details
        headers["Ice-Name"] = details.name unless details.name.empty?
        headers["Ice-Genre"] = details.genre unless details.genre.empty?
        headers["Ice-Description"] = details.description unless details.description.empty?
        headers["Ice-URL"] = details.url unless details.url.empty?
        headers["Ice-Public"] = details.listed ? "1" : "0"
      end
      output = Output.new(@server, @entry.mount, headers, encoder.channels, encoder.pre_skip)
      @mutex.synchronize { @output = output }
      output
    end

    private def close_output : Nil
      output = @mutex.synchronize do
        current = @output
        @output = nil
        current
      end
      output.try(&.close)
    end

    # Sets the source's current title on the target once the target mount is up.
    private def apply_title(output : Output) : Bool
      point = output.mount_point || return false
      title = @mutex.synchronize { @title }
      point.update_metadata(title) unless title.empty?
      true
    end
  end
end
