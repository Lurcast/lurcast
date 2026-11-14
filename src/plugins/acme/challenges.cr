require "http/headers"
require "http/request"
require "http/status"

module Lurcast::AcmeSupport
  # The http-01 key authorizations being answered, by token.
  class Challenges
    PREFIX = "/.well-known/acme-challenge/"

    @tokens = {} of String => String
    @mutex = Mutex.new

    def add(token : String, key_authorization : String) : Nil
      @mutex.synchronize { @tokens[token] = key_authorization }
    end

    def remove(token : String) : Nil
      @mutex.synchronize { @tokens.delete(token) }
    end

    def [](token : String) : String?
      @mutex.synchronize { @tokens[token]? }
    end

    def size : Int32
      @mutex.synchronize { @tokens.size }
    end

    # The key authorization for a challenge request path; nil when *path* is not a challenge path
    # or the token is unknown.
    def answer(path : String) : String?
      return unless path.starts_with?(PREFIX)
      self[path.lchop(PREFIX)]
    end
  end

  record HttpResponse, status : Int32, body : String, headers : HTTP::Headers = HTTP::Headers.new do
    def write(io : IO, head = false) : Nil
      io << "HTTP/1.1 " << status << ' ' << HTTP::Status.new(status).description << "\r\n"
      io << "Content-Type: text/plain; charset=utf-8\r\n"
      io << "Content-Length: " << body.bytesize << "\r\n"
      headers.each { |name, values| values.each { |value| io << name << ": " << value << "\r\n" } }
      io << "Connection: close\r\n\r\n"
      io << body unless head
      io.flush
    end
  end

  # Answers requests on the plain HTTP port: http-01 challenges, and either a redirect to HTTPS or
  # 404 for everything else.
  class HttpResponder
    def initialize(@challenges : Challenges, @domains : Array(String), @https_port : Int32, @redirect : Bool)
    end

    def answer(request : HTTP::Request) : HttpResponse
      path = request.path
      if path.starts_with?(Challenges::PREFIX)
        return HttpResponse.new(405, "Method not allowed\n", HTTP::Headers{"Allow" => "GET, HEAD"}) unless request.method.in?("GET", "HEAD")
        if key_authorization = @challenges.answer(path)
          return HttpResponse.new(200, key_authorization)
        end
        return HttpResponse.new(404, "Unknown challenge\n")
      end
      return HttpResponse.new(404, "Not found\n") unless @redirect
      HttpResponse.new(301, "Moved to HTTPS\n", HTTP::Headers{"Location" => redirect_url(request)})
    end

    # The HTTPS URL for *request*: the requested host when it is one of the domains, else the first.
    def redirect_url(request : HTTP::Request) : String
      host = request.headers["Host"]?.try(&.sub(/:\d+\z/, "").downcase)
      host = @domains.first unless host && @domains.includes?(host)
      port = @https_port == 443 ? "" : ":#{@https_port}"
      resource = request.resource
      resource = "/" if !resource.starts_with?('/') || resource.starts_with?("//")
      "https://#{host}#{port}#{resource}"
    end

    # Serves one connection: reads a request, answers it, and closes.
    def serve(client : IO) : Nil
      request = HTTP::Request.from_io(client, max_request_line_size: 8192, max_headers_size: 16_384)
      case request
      when HTTP::Request
        answer(request).write(client, head: request.method == "HEAD")
      when HTTP::Status
        HttpResponse.new(request.code, "#{request.description}\n").write(client)
      end
    rescue IO::Error
    ensure
      client.close rescue nil
    end
  end
end
