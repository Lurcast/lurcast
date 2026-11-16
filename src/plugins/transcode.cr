require "http/headers"
require "../plugin"

module Lurcast::Plugins
  # Re-encodes a mount on another mount, for example a low-bitrate Opus version of a live stream for
  # mobile listeners, or an MP3 copy of an Opus stream for older players. The source mount can be
  # MP3, Ogg Vorbis or Ogg Opus, and AAC when the Fraunhofer FDK AAC library is installed; the target
  # mount exists while the source has a source client, and follows the source's song titles.
  #
  # ```yaml
  # plugins:
  #   transcode:
  #     streams:
  #       - source: /live        # mount to read
  #         mount: /live.opus    # mount to publish
  #         codec: opus          # opus (Ogg Opus), mp3, or aac (needs libfdk-aac); default opus
  #         profile: lc          # for aac: lc, he (HE-AAC), or hev2 (HE-AAC v2, stereo only)
  #         bitrate: 64          # kbps; default 64 for Opus, 128 for MP3 and AAC-LC, 48 for HE-AAC
  #         channels: 2          # 1 or 2 (default 2)
  # ```
  class Transcode < Plugin
    register "transcode"

    CODECS = {"opus", "mp3", "aac"}

    # One stream to publish.
    class Entry
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter source : String
      getter mount : String
      getter codec : String = "opus"
      # The AAC profile: lc, he or hev2.
      getter profile : String = "lc"
      # 0 until `after_initialize` sets the codec's default.
      getter bitrate : Int32 = 0
      getter channels : Int32 = 2

      def_equals_and_hash source, mount, bitrate, channels, codec, profile

      def after_initialize
        return unless @bitrate.zero?
        @bitrate = case {codec, profile}
                   when {"opus", _}     then 64
                   when {"aac", "he"}   then 48
                   when {"aac", "hev2"} then 32
                   else                      128
                   end
      end

      # The bit rates the codec takes, in kbps, as text for an error message, or nil when *bitrate* is one.
      def bitrate_error : String?
        case codec
        when "opus" then "6 to 256 kbps" unless 6 <= bitrate <= 256
        when "mp3"  then "one of #{MP3Encoder::BITRATES.join(", ")} kbps" unless MP3Encoder::BITRATES.includes?(bitrate)
        when "aac"  then "8 to 320 kbps" unless 8 <= bitrate <= 320
        end
      end
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
          invalid("codec for #{entry.mount} must be opus, mp3 or aac") unless CODECS.includes?(entry.codec)
          entry.bitrate_error.try { |range| invalid("bitrate for #{entry.mount} must be #{range}") }
          invalid("channels for #{entry.mount} must be 1 or 2") unless entry.channels.in?(1, 2)
          validate_aac!(entry) if entry.codec == "aac"
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

      # AAC needs FDK; trying the encoder also checks the profile, bit rate and channels with it.
      private def validate_aac!(entry : Entry) : Nil
        invalid("profile for #{entry.mount} must be lc, he or hev2") unless AACEncoder::PROFILES.has_key?(entry.profile)
        invalid("hev2 for #{entry.mount} needs 2 channels") if entry.profile == "hev2" && entry.channels != 2
        fdk = FDK.library || invalid("codec aac for #{entry.mount} needs the Fraunhofer FDK AAC library (libfdk-aac): #{FDK.error}")
        AACEncoder.new(entry.bitrate, entry.channels, entry.profile, fdk).close
      rescue ex : ArgumentError
        invalid("#{entry.mount}: #{ex.message}")
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
