require "http/headers"
require "http/params"
require "http/request"
require "json"

module Lurcast
  abstract class Plugin < Extension
    # Ends a route with an error response: raised by `Context#halt`.
    class Halt < Exception
      getter status : Int32

      def initialize(@status : Int32, message : String)
        super(message)
      end
    end

    # One request to a plugin route, with helpers to read it and answer it.
    class Context
      NO_STORE = HTTP::Headers{"Cache-Control" => "no-store"}

      getter server : IcecastServer
      getter client : IO
      getter request : HTTP::Request
      getter address : String
      @access : AdminAccess?

      def initialize(@server : IcecastServer, @client : IO, @request : HTTP::Request, @address : String)
      end

      # The admin login of an `admin: true` route.
      def access : AdminAccess
        @access || raise "#{request.path} is not an admin route"
      end

      def path : String
        request.path
      end

      def head? : Bool
        request.method == "HEAD"
      end

      def params : HTTP::Params
        request.query_params
      end

      def headers : HTTP::Headers
        request.headers
      end

      # The query parameter *name*, stripped; halts with 400 when it is missing or empty.
      def param(name : String) : String
        params[name]?.try(&.strip).presence || halt(400, "#{name} is required")
      end

      # The mount named by the query parameter *name*, which the admin login may manage; halts with
      # 404 otherwise.
      def mount(name = "mount") : String
        mount = params[name]?.try { |value| server.mount_name(value) }
        halt(404, "Stream not found") unless mount && (@access.nil? || access.allows?(mount))
        mount
      end

      def halt(status : Int32, message : String) : NoReturn
        raise Halt.new(status, message)
      end

      def text(body : String, status = 200) : Nil
        bytes(body.to_slice, "text/plain; charset=utf-8", status: status)
      end

      def json(value, status = 200) : Nil
        bytes(value.to_json.to_slice, "application/json", NO_STORE, status)
      end

      def bytes(body : Bytes, content_type : String, headers : HTTP::Headers? = nil, status = 200) : Nil
        server.respond_bytes(client, status, body, content_type, headers, head: head? || status == 304)
      end

      def error(status : Int32, message : String) : Nil
        json({error: message}, status)
      end

      # Runs a route: asks for an admin login first when *admin* is true, and answers a `Halt`.
      def run(admin : Bool, &) : Nil
        if admin
          unless @access = server.admin_login(headers)
            return server.challenge(client, "Lurcast Admin")
          end
        end
        yield
      rescue ex : Halt
        error(ex.status, ex.message || "Error")
      end
    end
  end
end
