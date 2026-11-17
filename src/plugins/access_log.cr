require "log"
require "../plugin"

module Lurcast::Plugins
  # Writes one line per HTTP request in the combined log format Icecast uses, with the request's
  # duration in seconds at the end:
  #
  #   203.0.113.7 - admin [13/Nov/2026:22:01:14 +0000] "GET /live HTTP/1.1" 200 1048576 "-" "VLC/3.0.20" 125
  #
  # Listener lines are written when the listener disconnects. Passwords in query strings are masked.
  # Lines go through a bounded queue to a writer fiber, so a slow disk never blocks a connection.
  # A configuration reload (`kill -HUP`) reopens the file, for log rotation.
  #
  # ```yaml
  # plugins:
  #   access_log:
  #     path: /var/log/lurcast/access.log   # "-" for standard output
  # ```
  class AccessLog < Plugin
    register "access_log"

    QUEUE_SIZE    = 8192
    SECRET_PARAMS = /([?&](?:pass|password|pwd|key|token)=)[^&\s]*/i
    TIME_FORMAT   = "%d/%b/%Y:%H:%M:%S %z"

    class Settings < Plugin::Settings
      getter path : String = ""

      def enabled? : Bool
        @enabled && !path.empty?
      end
    end

    @writer : Writer?
    @mutex = Mutex.new

    def start(server : IcecastServer) : Nil
      writer = Writer.new(settings.path)
      @mutex.synchronize { @writer = writer }
    end

    def logs_requests? : Bool
      !@writer.nil?
    end

    def request_finished(request : RequestRecord) : Nil
      @writer.try(&.log(AccessLog.format(request)))
    end

    def stop : Nil
      @mutex.synchronize { @writer.tap { @writer = nil } }.try(&.close)
    end

    # Reopens the file, or opens the new one when the path changed.
    def reload(settings : Settings?) : Nil
      old = @mutex.synchronize do
        writer = @writer
        if settings && writer && writer.path == settings.path
          writer.reopen
          next
        end
        @settings = settings if settings
        @writer = settings.try { |current| Writer.new(current.path) }
        writer
      end
      old.try(&.close)
    end

    def self.format(entry : RequestRecord) : String
      String.build do |line|
        line << entry.address << " - " << field(entry.user) << " ["
        entry.started_at.to_s(line, TIME_FORMAT)
        line << "] \"" << sanitize(entry.method) << ' ' << sanitize(mask(entry.target)) << ' ' << sanitize(entry.version) << "\" "
        line << entry.status << ' ' << entry.bytes << " \"" << field(entry.referer) << "\" \"" << field(entry.user_agent) << "\" "
        line << entry.duration.total_seconds.to_i64
      end
    end

    def self.mask(target : String) : String
      target.gsub(SECRET_PARAMS) { "#{$1}*****" }
    end

    private def self.field(value : String?) : String
      value.presence.try { |text| sanitize(text) } || "-"
    end

    private def self.sanitize(value : String) : String
      value.gsub(/[\x00-\x1f\x7f"\\]/) { |char| char == "\"" ? "\\\"" : char == "\\" ? "\\\\" : " " }
    end

    # Writes lines to the file from its own fiber.
    class Writer
      @queue = Channel(String).new(QUEUE_SIZE)
      @io : IO
      @dropped = Atomic(Int64).new(0_i64)
      @reopen = Atomic(Bool).new(false)

      getter path : String

      def initialize(@path : String)
        @io = open
        spawn write_loop, name: "access log writer"
      end

      def log(line : String) : Nil
        select
        when @queue.send(line)
        else
          @dropped.add(1)
        end
      rescue Channel::ClosedError
      end

      # Reopens the file, so log rotation tools can move it away and then reload the server.
      def reopen : Nil
        @reopen.set(true)
      end

      def close : Nil
        @queue.close
      end

      private def write_loop
        flushed_at = Time.instant
        loop do
          select
          when line = @queue.receive?
            break unless line
            @io.puts line
            next unless Time.instant - flushed_at >= 1.second
          when timeout(1.second)
          end
          @io.flush
          flushed_at = Time.instant
          if (dropped = @dropped.swap(0)).positive?
            Log.warn { "Access log fell behind; #{dropped} lines were dropped" }
          end
          if @reopen.swap(false)
            @io.close unless @io == STDOUT
            @io = open
          end
        end
      rescue ex
        Log.error(exception: ex) { "Access log #{@path} failed" }
      ensure
        @io.flush rescue nil
        @io.close unless @io == STDOUT
      end

      private def open : IO
        return STDOUT if @path == "-"
        Dir.mkdir_p(File.dirname(@path))
        File.open(@path, "a")
      end
    end
  end
end
