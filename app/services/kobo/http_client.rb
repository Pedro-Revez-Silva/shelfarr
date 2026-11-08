# frozen_string_literal: true

require "net/http"

module Kobo
  # Only these two origins are reachable. No redirects, cookie jar, proxy from
  # the environment, browser session, or caller-selected host is used.
  class HttpClient
    HOSTS = { auth: "auth.kobobooks.com", store: "storeapi.kobo.com" }.freeze
    USER_AGENT = "Mozilla/5.0 (Linux; U; Android 2.0; en-us;) AppleWebKit/538.1 (KHTML, like Gecko) Version/4.0 Mobile Safari/538.1 (Kobo Touch 0373/4.38.23171)"
    MAX_BYTES = 4.megabytes
    Response = Data.define(:body, :headers)
    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    def call(origin:, path:, method: :get, body: nil, headers: {})
      host = HOSTS.fetch(origin)
      unless path.start_with?("/") && !path.start_with?("//") && !path.match?(/[\r\n\x00\\]/) && %i[get post].include?(method)
        raise Error, "protocol_changed"
      end
      request_class = method == :get ? Net::HTTP::Get : Net::HTTP::Post
      request = request_class.new(path, { "User-Agent" => USER_AGENT, "Accept" => "application/json", "Accept-Encoding" => "identity" }.merge(headers))
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      http = Net::HTTP.new(host, 443, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 5
      http.read_timeout = 10
      http.write_timeout = 10
      http.max_retries = 0
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      http.start do |connection|
        connection.request(request) do |response|
          raise Error, "credentials_expired" if %w[401 403].include?(response.code)
          raise Error, "provider_unavailable" if response.code == "429" || response.code.to_i >= 500
          raise Error, "protocol_changed" unless %w[200 201].include?(response.code)
          raise Error, "protocol_changed" if response["content-length"].to_i > MAX_BYTES || ![ nil, "", "identity" ].include?(response["content-encoding"])

          data = +"".b
          response.read_body do |chunk|
            if data.bytesize + chunk.bytesize > MAX_BYTES || Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 25
              raise Error, "protocol_changed"
            end
            data << chunk
          end
          return Response.new(body: data, headers: response.each_header.select { |key, _| key.start_with?("x-kobo-") }.to_h)
        end
      end
    rescue SocketError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, Net::ProtocolError, Net::HTTPBadResponse
      raise Error, "provider_unavailable"
    end
  end
end
