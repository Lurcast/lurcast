require "http/client"
require "json"
require "log"
require "uri"
require "./crypto"

module Lurcast::AcmeSupport
  Log = ::Log.for("acme")

  # Raised for ACME problems (RFC 8555 section 6.7) and protocol failures.
  class AcmeError < Exception
    getter type : String?

    def initialize(message : String, @type : String? = nil)
      super(message)
    end
  end

  # The ACME (RFC 8555) client: registers an account and orders a certificate, answering http-01
  # challenges through *challenges*.
  class Client
    BAD_NONCE        = "urn:ietf:params:acme:error:badNonce"
    JOSE_JSON        = "application/jose+json"
    AUTHZ_TIMEOUT    = 3.minutes
    ORDER_TIMEOUT    = 5.minutes
    DEFAULT_INTERVAL = 2.seconds

    record Directory, new_nonce : String, new_account : String, new_order : String

    getter account_url : String?
    # The nonce for the next request; normally taken from the last response.
    setter nonce : String?

    @directory : Directory?
    @nonce : String?

    # *sleeper* waits between polls; the plugin passes one that stops when the server stops.
    def initialize(@directory_url : String, @account_key : Key, @challenges : Challenges,
                   @tls : OpenSSL::SSL::Context::Client? = nil, @timeout : Time::Span = 30.seconds,
                   @sleeper : Proc(Time::Span, Nil) = ->(span : Time::Span) { sleep span; nil })
    end

    def directory : Directory
      @directory ||= begin
        response = request("GET", @directory_url)
        raise AcmeError.new("Could not read the ACME directory #{@directory_url}: HTTP #{response.status_code}") unless response.success?
        json = JSON.parse(response.body)
        Directory.new(json["newNonce"].as_s, json["newAccount"].as_s, json["newOrder"].as_s)
      rescue ex : JSON::ParseException | KeyError | TypeCastError
        raise AcmeError.new("Invalid ACME directory at #{@directory_url}: #{ex.message}")
      end
    end

    # Creates the account for the key, or finds the existing one, accepting the terms of service.
    def register(email : String?) : String
      payload = JSON.build do |json|
        json.object do
          json.field "termsOfServiceAgreed", true
          json.field("contact") { json.array { json.string "mailto:#{email}" } } if email
        end
      end
      response = post(directory.new_account, payload, use_jwk: true)
      @account_url = response.headers["Location"]? || raise AcmeError.new("The CA did not return an account URL")
    end

    # Orders a certificate for *domains* whose key is *certificate_key* and returns the PEM chain.
    def obtain(domains : Array(String), certificate_key : Key, email : String? = nil) : String
      register(email) unless @account_url
      payload = {identifiers: domains.map { |domain| {type: "dns", value: domain} }}.to_json
      response = post(directory.new_order, payload)
      order_url = response.headers["Location"]? || raise AcmeError.new("The CA did not return an order URL")
      order = parse(response)
      order["authorizations"].as_a.each { |authorization| authorize(authorization.as_s) }

      order = poll(order_url, "order", {"ready", "valid"}, ORDER_TIMEOUT) unless order["status"].as_s.in?("ready", "valid")
      if order["status"].as_s == "ready"
        csr = AcmeSupport.base64url(AcmeSupport.csr(certificate_key, domains))
        order = parse(post(order["finalize"].as_s, {csr: csr}.to_json))
      end
      order = poll(order_url, "order", {"valid"}, ORDER_TIMEOUT) unless order["status"].as_s == "valid"
      certificate_url = order["certificate"]?.try(&.as_s) || raise AcmeError.new("The order has no certificate URL")
      chain = post(certificate_url, nil, accept: "application/pem-certificate-chain").body
      raise AcmeError.new("The CA returned no certificate") unless chain.includes?("-----BEGIN CERTIFICATE-----")
      chain
    rescue ex : KeyError | TypeCastError
      raise AcmeError.new("Unexpected response from the CA: #{ex.message}")
    end

    private def authorize(url : String) : Nil
      authorization = parse(post(url, nil))
      return if authorization["status"].as_s == "valid"
      domain = authorization["identifier"]["value"].as_s
      challenge = authorization["challenges"].as_a.find { |item| item["type"].as_s == "http-01" }
      raise AcmeError.new("The CA offers no http-01 challenge for #{domain}") unless challenge
      token = challenge["token"].as_s
      @challenges.add(token, "#{token}.#{@account_key.thumbprint}")
      begin
        Log.info { "Answering the http-01 challenge for #{domain}" }
        post(challenge["url"].as_s, "{}")
        poll(url, "authorization for #{domain}", {"valid"}, AUTHZ_TIMEOUT)
      ensure
        @challenges.remove(token)
      end
    end

    # POSTs-as-GET *url* until its status is one of *wanted*, failing on "invalid" or a timeout.
    private def poll(url : String, what : String, wanted : Tuple, timeout : Time::Span) : JSON::Any
      deadline = Time.instant + timeout
      loop do
        response = post(url, nil)
        json = parse(response)
        status = json["status"].as_s
        return json if status.in?(wanted)
        raise AcmeError.new("The #{what} is #{status}#{failure_detail(json)}") if status.in?("invalid", "revoked", "deactivated", "expired")
        raise AcmeError.new("Timed out waiting for the #{what} (still #{status})") if Time.instant >= deadline
        @sleeper.call(retry_after(response))
      end
    end

    private def failure_detail(json : JSON::Any) : String
      errors = [json["error"]?] + (json["challenges"]?.try(&.as_a.map { |challenge| challenge["error"]? }) || [] of JSON::Any?)
      details = errors.compact.map { |error| error["detail"]?.try(&.as_s) || error.to_json }
      details.empty? ? "" : ": #{details.join("; ")}"
    end

    private def retry_after(response : HTTP::Client::Response) : Time::Span
      value = response.headers["Retry-After"]? || return DEFAULT_INTERVAL
      span = if seconds = value.to_i?
               seconds.seconds
             elsif time = HTTP.parse_time(value)
               time - Time.utc
             else
               DEFAULT_INTERVAL
             end
      span.clamp(1.second, 60.seconds)
    end

    # Sends a JWS-signed POST (POST-as-GET when *payload* is nil), retrying once with a fresh nonce
    # when the CA answers badNonce.
    def post(url : String, payload : String?, *, use_jwk = false, accept : String? = nil) : HTTP::Client::Response
      attempts = 0
      loop do
        attempts += 1
        headers = HTTP::Headers{"Content-Type" => JOSE_JSON}
        headers["Accept"] = accept if accept
        response = request("POST", url, jws(url, payload, use_jwk), headers)
        return response if response.success?
        error = problem(response)
        raise error unless error.type == BAD_NONCE && attempts < 2
        Log.debug { "Retrying #{url} after badNonce" }
      end
    end

    def jws(url : String, payload : String?, use_jwk = false) : String
      protected_header = JSON.build do |json|
        json.object do
          json.field "alg", "ES256"
          json.field "nonce", next_nonce
          json.field "url", url
          if !use_jwk && (account = @account_url)
            json.field "kid", account
          else
            json.field "jwk", @account_key.jwk
          end
        end
      end
      encoded_header = AcmeSupport.base64url(protected_header)
      encoded_payload = payload ? AcmeSupport.base64url(payload) : ""
      signature = @account_key.sign("#{encoded_header}.#{encoded_payload}")
      {protected: encoded_header, payload: encoded_payload, signature: AcmeSupport.base64url(signature)}.to_json
    end

    private def next_nonce : String
      if nonce = @nonce
        @nonce = nil
        return nonce
      end
      request("HEAD", directory.new_nonce)
      nonce = @nonce || raise AcmeError.new("The CA did not return a nonce")
      @nonce = nil
      nonce
    end

    private def problem(response : HTTP::Client::Response) : AcmeError
      json = JSON.parse(response.body) rescue nil
      type = json.try(&.["type"]?).try(&.as_s?)
      detail = json.try(&.["detail"]?).try(&.as_s?) || response.body[0, 200]
      AcmeError.new("ACME request failed (HTTP #{response.status_code}#{type ? ", #{type}" : ""}): #{detail}", type)
    end

    private def parse(response : HTTP::Client::Response) : JSON::Any
      JSON.parse(response.body)
    rescue ex : JSON::ParseException
      raise AcmeError.new("Invalid JSON from the CA: #{ex.message}")
    end

    private def request(method : String, url : String, body : String? = nil, headers = HTTP::Headers.new) : HTTP::Client::Response
      uri = URI.parse(url)
      client = HTTP::Client.new(uri, uri.scheme == "https" ? @tls : nil)
      client.connect_timeout = 15.seconds
      client.read_timeout = @timeout
      client.write_timeout = @timeout
      headers["User-Agent"] = "Lurcast/#{Lurcast::VERSION}"
      begin
        response = client.exec(method, uri.request_target, headers, body)
        response.headers["Replay-Nonce"]?.try { |nonce| @nonce = nonce }
        response
      ensure
        client.close
      end
    end
  end
end
