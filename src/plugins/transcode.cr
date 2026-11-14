require "http/headers"
require "../plugin"

module Lurcast::Plugins
  # Re-encodes a mount as Opus in Ogg on another mount, for example a low-bitrate version of a live
  # MP3 stream for mobile listeners. The source mount can be MP3, Ogg Vorbis or Ogg Opus; the target
  # mount exists while the source has a source client, and follows the source's song titles.
  #
  # ```yaml
  # plugins:
  #   transcode:
  #     streams:
  #       - source: /live        # mount to read
  #         mount: /live.opus    # mount to publish
  #         bitrate: 64          # kbps, 6 to 256 (default 64)
  #         channels: 2          # 1 or 2 (default 2)
  #         codec: opus          # the only codec for now
  # ```
  class Transcode < Plugin
    register "transcode"

    BITRATES = 6..256

    # One stream to publish.
    class Entry
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter source : String
      getter mount : String
      getter bitrate : Int32 = 64
      getter channels : Int32 = 2
      getter codec : String = "opus"

      def_equals_and_hash source, mount, bitrate, channels, codec
    end

    class Settings < Plugin::Settings
      getter streams : Array(Entry) = [] of Entry

      # Without streams there is nothing to do.
      def enabled? : Bool
        @enabled && !streams.empty?
      end

      def validate!(config : Config) : Nil
        targets = {} of String => Entry
        streams.each do |entry|
          {entry.source, entry.mount}.each do |mount|
            invalid("mount names must start with /: #{mount.inspect}") unless mount.starts_with?('/') && mount.size > 1
          end
          invalid("#{entry.mount} can't transcode itself") if entry.mount == entry.source
          invalid("bitrate for #{entry.mount} must be #{BITRATES.begin} to #{BITRATES.end} kbps") unless BITRATES.includes?(entry.bitrate)
          invalid("channels for #{entry.mount} must be 1 or 2") unless entry.channels.in?(1, 2)
          invalid("codec for #{entry.mount} must be opus") unless entry.codec == "opus"
          invalid("#{entry.mount} is the target of more than one stream") if targets.has_key?(entry.mount)
          targets[entry.mount] = entry
        end
        # Each mount has at most one stream publishing it, so following sources back from a stream
        # either ends or comes back around to it.
        streams.each do |entry|
          current = entry.source
          targets.size.times do
            feeding = targets[current]? || break
            invalid("#{entry.mount} feeds back into itself through #{current}") if feeding.source == entry.mount
            current = feeding.source
          end
        end
      end
    end

    @transcoders = {} of String => Transcoder
    @server : IcecastServer?
    @mutex = Mutex.new

    def entries : Array(Entry)
      @mutex.synchronize { settings.streams }
    end

    def start(server : IcecastServer) : Nil
      @mutex.synchronize do
        @server = server
        settings.streams.each { |entry| start_transcoder(server, entry) }
      end
    end

    def stop : Nil
      transcoders = @mutex.synchronize do
        @server = nil
        stopping = @transcoders.values
        @transcoders.clear
        stopping
      end
      transcoders.each(&.stop)
    end

    def song_changed(mount : String, song : String, listeners : Int32, at : Time) : Nil
      transcoders = @mutex.synchronize { @transcoders.values.select { |transcoder| transcoder.entry.source == mount } }
      transcoders.each(&.title=(song))
    end

    # Starts streams that were added, stops removed ones and restarts changed ones. A removed
    # section stops them all.
    def reload(settings : Settings?) : Nil
      settings ||= Settings.from_yaml("enabled: false")
      stopped = [] of Transcoder
      @mutex.synchronize do
        @settings = settings
        return unless @server
        wanted = settings.streams.to_h { |entry| {entry.mount, entry} }
        @transcoders.select! do |mount, transcoder|
          keep = wanted[mount]? == transcoder.entry
          stopped << transcoder unless keep
          keep
        end
      end
      # A restarted stream publishes the same mount, so the old transcoder must let go of it first.
      stopped.each(&.stop)
      stopped.each(&.wait(5.seconds))
      @mutex.synchronize do
        server = @server || return
        @settings.streams.each { |entry| start_transcoder(server, entry) unless @transcoders.has_key?(entry.mount) }
      end
    end

    private def start_transcoder(server : IcecastServer, entry : Entry) : Nil
      transcoder = Transcoder.new(server, entry)
      @transcoders[entry.mount] = transcoder
      transcoder.start
    end
  end
end

require "./transcode/transcoder"
