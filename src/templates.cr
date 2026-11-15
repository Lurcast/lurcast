require "ecr"
require "html"
require "./mount_point"
require "./web_assets"

# Server-rendered HTML pages, from the ECR templates in `web/views`. Every value from a source,
# listener, or configuration goes through `h`. The pages work without JavaScript; `status.js` and
# `admin.js` add live updates.
module Templates
  # The Lurcast logo mark from lurcast.com; it takes the text colour, with copper sound waves.
  LOGO_MARK = %(<svg class="brand__mark" viewBox="0 0 32 32" fill="none" stroke-linecap="round" aria-hidden="true"><circle cx="4.5" cy="28" r="1.6" fill="currentColor"/><path d="M4.5 28C8.5 27.5 9.5 23 12 20.2S17 15 19 13" stroke="currentColor" stroke-width="2.4"/><path d="M16.2 10.2 21.8 15.8" stroke="currentColor" stroke-width="2.4"/><g stroke="#d89c60" stroke-width="2"><path d="M20 7.4A5.6 5.6 0 0 1 24.6 12"/><path d="M20.4 3.2A9.6 9.6 0 0 1 28.8 11.6"/></g></svg> = %(<svg class="brand__mark" viewBox="0 0 32 32" fill="none" stroke-linecap="round" aria-hidden="true"><circle cx="4.5" cy="28" r="1.6" fill="currentColor"/><path d="M4.5 28C8.5 27.5 9.5 23 12 20.2S17 15 19 13" stroke="currentColor" stroke-width="2.4"/><path d="M16.2 10.2 21.8 15.8" stroke="currentColor" stroke-width="2.4"/><g stroke="#d89c60" stroke-width="2"><path d="M20 7.4A5.6 5.6 0 0 1 24.6 12"/><path d="M20.4 3.2A9.6 9.6 0 0 1 28.8 11.6"/></g></svg>))

  ICON_PLAY  = %(<svg class="icon-play" viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M8 5.5v13a1 1 0 0 0 1.5.86l10.5-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5Z"/></svg>)
  ICON_PAUSE = %(<svg class="icon-pause" viewBox="0 0 24 24" aria-hidden="true"><rect x="6" y="5" width="4.5" height="14" rx="1.2" fill="currentColor"/><rect x="13.5" y="5" width="4.5" height="14" rx="1.2" fill="currentColor"/></svg>)

  FOOTER = %(<footer class="page__foot"><span>Streams also open in any player that reads <span class="mono">.m3u</span> links.</span><span>Powered by <a href="https://lurcast.com" rel="noopener">Lurcast</a></span></footer>)

  # Escapes text for HTML, in templates.
  module Helpers
    private def h(value : String) : String
      HTML.escape(value)
    end
  end

  # The document around every page.
  struct Layout
    include Helpers

    def initialize(@title : String, @body : String, @scripts : Array(String), @robots = false)
    end

    ECR.def_to_s "#{__DIR__}/web/views/layout.ecr"
  end

  # The public status page: live stations first, then offline ones, each by mount.
  struct StatusPage
    include Helpers

    @streams : Array(MountPoint)

    def initialize(streams : Array(MountPoint))
      @streams = streams.sort_by { |stream| {stream.has_source? ? 0 : 1, stream.mount} }
    end

    ECR.def_to_s "#{__DIR__}/web/views/status.ecr"

    private def live_count : Int32
      @streams.count(&.has_source?)
    end

    private def listener_count : Int32
      @streams.sum(&.listener_count)
    end

    private def web_url?(url : String) : Bool
      url.starts_with?("http://") || url.starts_with?("https://")
    end
  end

  # SHOUTcast's song history page. Each row keeps the `<td>time</td><td>title</td>` shape that
  # scrapers of the original page expect.
  struct PlayedPage
    include Helpers

    def initialize(@history : Array(MountPoint::PlayedSong), @title : String)
    end

    ECR.def_to_s "#{__DIR__}/web/views/played.ecr"
  end

  # The admin dashboard shell. `admin.js` renders the dashboard from `/admin/api/overview`.
  struct AdminPage
    ECR.def_to_s "#{__DIR__}/web/views/admin.ecr"
  end

  # The public status page, served at `/`, `/status.xsl`, and `/status.html`.
  def self.index(streams : Array(MountPoint)) : String
    Layout.new("Live streams", StatusPage.new(streams).to_s, ["status.js"]).to_s
  end

  def self.played(history : Array(MountPoint::PlayedSong), title : String) : String
    Layout.new("#{title} - Song history", PlayedPage.new(history, title).to_s, ["status.js"]).to_s
  end

  def self.admin : String
    Layout.new("Lurcast admin", AdminPage.new.to_s, ["plugins.js", "admin.js"], robots: true).to_s
  end

  def self.format_label(content_type : String, bitrate : Int32) : String
    format = case content_type.split(';').first.strip.downcase
             when "audio/mpeg", "audio/mp3"                     then "MP3"
             when "audio/aac", "audio/aacp", "audio/x-aac"      then "AAC"
             when "audio/ogg", "application/ogg", "audio/x-ogg" then "Ogg"
             when "audio/opus"                                  then "Opus"
             when "audio/flac", "audio/x-flac"                  then "FLAC"
             when "video/ogg", "video/webm", "audio/webm"       then "WebM"
             when ""                                            then "Audio"
             else                                                    content_type
             end
    bitrate.positive? ? "#{format} · #{bitrate} kbps" : format
  end
end
