require "log"
require "socket"
require "uri"
require "../plugin"
require "./acme/crypto"
require "./acme/challenges"
require "./acme/client"

module Lurcast::Plugins
  # Automatic HTTPS: obtains a certificate from Let's Encrypt (or another ACME CA) for the configured
  # domains with the http-01 challenge, serves HTTPS on `https_port` with it, and renews it before
  # it expires. The account key and certificate are kept in `data_dir/acme/`.
  #
  # ```yaml
  # data_dir: /var/lib/lurcast
  # plugins:
  #   acme:
  #     domains: [radio.example.com]
  #     email: ops@example.com
  #     accept_terms: true
  # ```
  class ACME < Plugin
    register "acme"

    LETS_ENCRYPT   = "https://acme-v02.api.letsencrypt.org/directory"
    CHECK_INTERVAL = 12.hours
    FIRST_RETRY    = 1.minute
    MAX_RETRY      = 6.hours
    MAX_DOMAINS    = 100
    # For testing against a private CA such as Pebble: a PEM bundle to trust for the ACME directory.
    CA_FILE_ENV = "LURCAST_ACME_CA_FILE"
    LOCAL_HOSTS = {"localhost", "127.0.0.1", "[::1]", "::1"}
    DOMAIN      = /\A(?=.{1,253}\z)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/

    class Settings < Plugin::Settings
      getter domains : Array(String) = [] of String
      getter email : String?
      getter? accept_terms : Bool = false
      getter https_port : Int32 = 443
      getter http_port : Int32 = 80
      getter? redirect_http : Bool = false
      getter directory : String = LETS_ENCRYPT
      getter renew_days : Int32 = 30

      # Also normalizes the domain names: lower case, without a trailing dot or duplicates.
      def validate!(config : Config) : Nil
        invalid("data_dir is required to keep the account key and certificate") unless config.data_dir.presence
        if config.tls_port || config.tls_cert || config.tls_key
          invalid("remove tls_port, tls_cert, and tls_key; use either the acme plugin or your own certificate, not both")
        end
        @domains = domains.map(&.strip.downcase.chomp('.')).uniq!
        validate_domains!
        invalid("accept_terms must be true to accept the certificate authority's terms of service") unless accept_terms?
        if email = @email
          invalid("email #{email.inspect} is not a valid address") unless email.matches?(/\A[^@\s,]+@[^@\s,]+\.[^@\s,]+\z/)
        end
        validate_ports!(config)
        invalid("renew_days must be between 1 and 60") unless 1 <= renew_days <= 60
        validate_directory!
      end

      private def validate_domains! : Nil
        invalid("domains must list at least one domain name") if domains.empty?
        invalid("domains may list at most #{MAX_DOMAINS} names") if domains.size > MAX_DOMAINS
        domains.each do |domain|
          invalid("wildcard domains (#{domain}) need the dns-01 challenge, which is not supported") if domain.includes?('*')
          invalid("#{domain} is an IP address; certificates are issued for domain names only") if domain.matches?(/\A[\d.]+\z/) || domain.includes?(':')
          invalid("#{domain} is not a valid domain name") unless DOMAIN.matches?(domain)
        end
      end

      private def validate_ports!(config : Config) : Nil
        invalid("https_port must be between 1 and 65535") unless 1 <= https_port <= 65_535
        invalid("http_port must be between 0 and 65535 (0 turns it off)") unless 0 <= http_port <= 65_535
        invalid("redirect_http needs http_port") if redirect_http? && http_port.zero?
        invalid("https_port and http_port must differ") if https_port == http_port
        used = {"port" => config.port, "shoutcast_port" => config.shoutcast_port}
        {"https_port" => https_port, "http_port" => http_port}.each do |name, value|
          next if value.zero?
          used.each { |other, port| invalid("#{name} #{value} is already used by #{other}") if port == value }
        end
      end

      private def validate_directory! : Nil
        uri = URI.parse(directory)
        host = uri.host.presence || invalid("directory must be an https URL")
        return if uri.scheme == "https"
        return if uri.scheme == "http" && host.in?(LOCAL_HOSTS)
        invalid("directory must be an https URL (http is only allowed for localhost)")
      end
    end

    # Raised inside the plugin's fiber when the server stops.
    private class Stopped < Exception
    end

    getter challenges = ACMESupport::Challenges.new
    # The certificate being served, once there is one.
    getter certificate : ACMESupport::CertificateInfo?

    @stopped = Atomic(Bool).new(false)
    @wake = Channel(Nil).new(1)
    @http_listener : TCPServer?
    @https_listener : TCPServer?
    @served_pem : String?
    @client : ACMESupport::Client?

    def initialize(@config : Config, @settings : Settings)
      @data_dir = @config.data_dir || raise ArgumentError.new("plugins.acme: data_dir is required")
      @responder = ACMESupport::HTTPResponder.new(@challenges, domains, @settings.https_port, @settings.redirect_http?)
      @main_port_responder = ACMESupport::HTTPResponder.new(@challenges, domains, @settings.https_port, false)
    end

    def domains : Array(String)
      settings.domains
    end

    def start(server : IcecastServer) : Nil
      spawn run(server), name: "acme renewal"
    end

    def stop : Nil
      return if @stopped.swap(true)
      @wake.close
      @http_listener.try { |listener| listener.close rescue nil }
      @https_listener.try { |listener| listener.close rescue nil }
    end

    # Checks the certificate again at once, for example after it was replaced in `data_dir`. Other
    # changes to the settings need a restart.
    def reload(settings : Settings?) : Nil
      select
      when @wake.send(nil)
      else
      end
    rescue Channel::ClosedError
    end

    # Answers http-01 challenges on the main port too, for setups that forward port 80 to it.
    @[Route("GET", ACMESupport::Challenges::PREFIX, prefix: true)]
    private def challenge(context : Context) : Nil
      response = @main_port_responder.answer(context.request)
      context.server.respond(context.client, response.status, response.body, headers: response.headers)
    end

    # The directory holding this CA's account key and certificate.
    def storage_directory : String
      uri = URI.parse(@settings.directory)
      ca = [uri.host, uri.port].compact.join('_').gsub(/[^A-Za-z0-9.-]/, '_')
      File.join(@data_dir, "acme", ca)
    end

    private def run(server : IcecastServer) : Nil
      retry = FIRST_RETRY
      until @stopped.get
        begin
          start_http_listener
          wait_for = check(server)
          retry = FIRST_RETRY
          wait(wait_for)
        rescue Stopped
          break
        rescue ex
          break if @stopped.get
          Log.error { "Certificate for #{domains.join(", ")} not obtained: #{ex.message}; retrying in #{format_span(retry)}" }
          Log.debug(exception: ex) { "ACME failure details" }
          begin
            wait(retry)
          rescue Stopped
            break
          end
          retry = Math.min(retry * 2, MAX_RETRY)
        end
      end
    end

    # Makes sure a current certificate is served, obtaining or renewing it when needed, and returns
    # how long to wait before checking again.
    private def check(server : IcecastServer) : Time::Span
      current = load_certificate
      if reason = renewal_reason(current)
        Log.info { "Requesting a certificate for #{domains.join(", ")} from #{@settings.directory} (#{reason})" }
        issue
        current = load_certificate
      end
      raise "The new certificate in #{storage_directory} could not be read" unless current
      serve(server, current)
      due = renew_at(current) - Time.utc
      due.clamp(FIRST_RETRY, CHECK_INTERVAL)
    end

    # Why the certificate *info* must be replaced, or nil when it is fine.
    def renewal_reason(info : ACMESupport::CertificateInfo?, now = Time.utc) : String?
      return "no certificate yet" unless info
      return "the domain list changed" unless info.covers?(domains)
      "it expires #{info.not_after}" if now >= renew_at(info)
    end

    # When to renew: `renew_days` before expiry, but never earlier than halfway through the
    # certificate's lifetime, so short-lived certificates are not renewed over and over.
    def renew_at(info : ACMESupport::CertificateInfo) : Time
      info.not_after - Math.min(@settings.renew_days.days, info.lifetime / 2)
    end

    private def serve(server : IcecastServer, info : ACMESupport::CertificateInfo) : Nil
      pem = File.read(certificate_path)
      return if pem == @served_pem && @https_listener
      context = build_context
      if @https_listener
        server.tls_context = context
      else
        listener = TCPServer.new(@config.host, @settings.https_port)
        @https_listener = listener
        spawn serve_https(server, listener, context), name: "acme https accept"
      end
      Log.info { "Certificate for #{domains.join(", ")} valid until #{info.not_after}, served on port #{@settings.https_port}" }
      @served_pem = pem
      @certificate = info
    end

    private def serve_https(server : IcecastServer, listener : TCPServer, context : OpenSSL::SSL::Context::Server) : Nil
      server.serve_tls(listener, context)
    rescue ex
      Log.error(exception: ex) { "HTTPS on port #{@settings.https_port} stopped" } unless @stopped.get
    end

    private def build_context : OpenSSL::SSL::Context::Server
      context = OpenSSL::SSL::Context::Server.new
      context.certificate_chain = certificate_path
      context.private_key = certificate_key_path
      context
    end

    private def start_http_listener : Nil
      port = @settings.http_port
      return if port.zero? || @http_listener
      begin
        listener = TCPServer.new(@config.host, port)
      rescue ex : Socket::Error
        Log.error { "Could not listen for ACME challenges on port #{port}: #{ex.message}; challenges are still answered on port #{@config.port}" }
        return
      end
      @http_listener = listener
      Log.info { "ACME challenges#{@settings.redirect_http? ? " and HTTPS redirects" : ""} on #{listener.local_address}" }
      spawn accept_http(listener), name: "acme http accept"
    end

    private def accept_http(listener : TCPServer) : Nil
      while client = listener.accept?
        client.read_timeout = 10.seconds
        client.write_timeout = 10.seconds
        spawn @responder.serve(client), name: "acme http connection"
      end
    rescue ex : IO::Error
      Log.error { "ACME challenge listener stopped: #{ex.message}" } unless @stopped.get
    ensure
      @http_listener = nil unless @stopped.get
    end

    # Obtains a new certificate and stores it with its key.
    private def issue : Nil
      account_key = load_or_create_key(account_key_path)
      certificate_key = ACMESupport::Key.generate
      client = @client ||= ACMESupport::Client.new(@settings.directory, account_key, @challenges, tls: ca_context,
        sleeper: ->(span : Time::Span) { wait(span) })
      chain = client.obtain(domains, certificate_key, @settings.email)
      unless ACMESupport::CertificateInfo.parse(chain, certificate_key)
        raise "The CA returned a certificate that does not match the key"
      end
      write_private(certificate_key_path, certificate_key.to_pem)
      write_private(certificate_path, chain)
    end

    private def ca_context : OpenSSL::SSL::Context::Client?
      path = ENV[CA_FILE_ENV]?.presence || return
      context = OpenSSL::SSL::Context::Client.new
      context.ca_certificates = path
      context
    end

    # The stored certificate when it can be read and matches its key; nil otherwise.
    private def load_certificate : ACMESupport::CertificateInfo?
      return unless File.exists?(certificate_path) && File.exists?(certificate_key_path)
      key = ACMESupport::Key.from_pem(File.read(certificate_key_path))
      info = ACMESupport::CertificateInfo.parse(File.read(certificate_path), key)
      Log.warn { "The stored certificate does not match its key; requesting a new one" } unless info
      info
    rescue ex : ACMESupport::CryptoError | IO::Error
      Log.warn { "Could not read the stored certificate: #{ex.message}; requesting a new one" }
      nil
    end

    private def load_or_create_key(path : String) : ACMESupport::Key
      if File.exists?(path)
        ACMESupport::Key.from_pem(File.read(path))
      else
        key = ACMESupport::Key.generate
        write_private(path, key.to_pem)
        Log.info { "Created an ACME account key in #{path}" }
        key
      end
    end

    private def write_private(path : String, content : String) : Nil
      directory = File.dirname(path)
      Dir.mkdir_p(directory, 0o700)
      {File.dirname(directory), directory}.each { |dir| File.chmod(dir, 0o700) }
      Plugin.write_file(path, content)
    end

    private def account_key_path : String
      File.join(storage_directory, "account.key")
    end

    private def certificate_path : String
      File.join(storage_directory, "certificate.pem")
    end

    private def certificate_key_path : String
      File.join(storage_directory, "certificate.key")
    end

    # Sleeps for *span*, or raises `Stopped` as soon as the server stops.
    private def wait(span : Time::Span) : Nil
      raise Stopped.new if @stopped.get
      select
      when @wake.receive?
      when timeout(span)
      end
      raise Stopped.new if @stopped.get
    end

    private def format_span(span : Time::Span) : String
      span >= 1.hour ? "#{span.total_hours.round(1)} h" : "#{span.total_minutes.round.to_i} min"
    end
  end
end
