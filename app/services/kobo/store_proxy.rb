# frozen_string_literal: true

require "net/http"

module Kobo
  # Passes a physical reader's own Store request to Kobo. This is a protocol
  # relay, never a configurable fetcher: the only reachable origin is the stock
  # Store API, paths are validated, redirects are refused, and environment
  # proxies, cookies and Shelfarr credentials are never used. The reader's own
  # Authorization header is forwarded for this request only and never stored.
  class StoreProxy
    HOST = "storeapi.kobo.com"
    ORIGIN = "https://#{HOST}".freeze
    MAX_RESPONSE_BYTES = 8.megabytes
    MAX_HEADER_BYTES = 8.kilobytes
    MAX_QUERY_BYTES = 8.kilobytes
    METHODS = %w[GET HEAD POST PUT PATCH DELETE].freeze
    REQUEST_HEADERS = %w[authorization accept accept-language content-type user-agent if-none-match if-modified-since].freeze
    RESPONSE_HEADERS = %w[etag last-modified retry-after www-authenticate].freeze
    JSON_TYPE = %r{\Aapplication/(?:[\w.+-]+\+)?json(?:\s*;|\z)}i

    Response = Data.define(:status, :headers, :body) do
      def json(type = Hash)
        value = JSON.parse(FilenameBytes.utf8(body))
        raise StoreProxy::Unavailable unless value.is_a?(type)

        value
      rescue JSON::ParserError, EncodingError
        raise StoreProxy::Unavailable
      end
    end

    class Unavailable < StandardError; end
    class InvalidRequest < StandardError; end

    def call(method:, path:, query: "", headers: {}, body: nil, sync_token: nil)
      validate!(method, path, query.to_s, body)
      outgoing = forwarded(headers)
      # Shelfarr's combined cursor never reaches Kobo; only Kobo's own part does.
      outgoing["x-kobo-synctoken"] = sync_token if sync_token
      outgoing["accept-encoding"] = "identity"
      target = query.present? ? "#{path}?#{query}" : path
      request = Net::HTTPGenericRequest.new(method, body.present?, method != "HEAD", target, outgoing)
      request.body = body if body.present?

      http = Net::HTTP.new(HOST, 443, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 3
      http.read_timeout = 10
      http.write_timeout = 10
      http.max_retries = 0
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      http.start do |connection|
        connection.request(request) do |response|
          status = response.code.to_i
          raise Unavailable if status.between?(300, 399) && status != 304
          raise Unavailable unless [ nil, "", "identity" ].include?(response["content-encoding"])
          raise Unavailable if response["content-length"].to_i > MAX_RESPONSE_BYTES

          data = +"".b
          response.read_body do |chunk|
            if data.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES || Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 20
              raise Unavailable
            end
            data << chunk
          end
          return Response.new(status: status, headers: response_headers(response), body: data)
        end
      end
    rescue SocketError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
      raise Unavailable
    end

    def self.safe_header_value?(value, maximum = MAX_HEADER_BYTES)
      value.is_a?(String) && value.present? && value.bytesize <= maximum && !value.match?(/[\x00-\x1f\x7f]/)
    end

    private

    def validate!(method, path, query, body)
      valid = METHODS.include?(method) && path.is_a?(String) &&
        path.match?(%r{\A/(?:v[1-9]\d?|api)/[A-Za-z0-9._~!$&'()*+,;=:@%/-]*\z}) &&
        !path.match?(%r{//|(?:\A|/)\.\.?(?:/|\z)|%2e|%2f|%5c|%00}i) &&
        query.bytesize <= MAX_QUERY_BYTES && !query.match?(/[\x00-\x20\x7f#]/) &&
        body.to_s.bytesize <= KoboBodyLimit::MAX_BYTES
      raise InvalidRequest unless valid
    end

    def forwarded(headers)
      headers.each_with_object({}) do |(name, value), result|
        key = name.to_s.downcase
        next unless REQUEST_HEADERS.include?(key) || (key.start_with?("x-kobo-") && key != "x-kobo-synctoken")
        next unless self.class.safe_header_value?(value)

        result[key] = value
      end
    end

    def response_headers(response)
      result = {}
      response.each_header do |name, value|
        next unless RESPONSE_HEADERS.include?(name) || name.start_with?("x-kobo-")
        next unless self.class.safe_header_value?(value)

        result[name] = value
      end
      result["content-type"] = response["content-type"].to_s.match?(JSON_TYPE) ? "application/json; charset=utf-8" : "text/plain; charset=utf-8"
      result
    end
  end
end
