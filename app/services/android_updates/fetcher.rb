# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module AndroidUpdates
  # Bounded HTTPS GETs for the catalog and APKs. Sends no credentials or
  # cookies, follows only redirects the source policy allows (checking each
  # hop before connecting), asks for the exact bytes (no content coding) and
  # stops at the size and time limits. Errors name a category and a host,
  # never a URL: signed redirect URLs carry tokens.
  class Fetcher
    class Error < StandardError
      attr_reader :category

      def initialize(category, message)
        @category = category
        super(message)
      end
    end

    MAX_REDIRECTS = 5
    MAX_LOCATION_LENGTH = 8192
    REDIRECT_CODES = [ 301, 302, 303, 307, 308 ].freeze
    USER_AGENT = "Shelfarr Android update cache"
    NETWORK_ERRORS = [
      SocketError, IOError, EOFError, Timeout::Error, Net::ProtocolError, SystemCallError
    ].freeze

    def initialize(policy, open_timeout: 10, read_timeout: 30)
      @policy = policy
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def catalog(uri, max_bytes: Catalog::MAX_BYTES, deadline: 60)
      body = +""
      get(uri, max_bytes: max_bytes, deadline: deadline, accept: "application/json", first: :catalog) do |chunk|
        body << chunk
      end
      body
    end

    # Streams the APK into the block; returns the number of bytes received.
    def artifact(uri, max_bytes:, deadline: 30 * 60, &block)
      get(uri, max_bytes: max_bytes, deadline: deadline, accept: "application/vnd.android.package-archive",
        first: :artifact, &block)
    end

    private

    def get(uri, max_bytes:, deadline:, accept:, first:, &block)
      expires = monotonic + deadline
      current = uri.is_a?(URI) ? uri : URI.parse(uri.to_s)

      (MAX_REDIRECTS + 1).times do |hop|
        check_location!(current, hop.zero? ? first : :redirect)
        location = request(current, max_bytes: max_bytes, expires: expires, accept: accept, &block)
        return location if location.is_a?(Integer)

        current = next_location(current, location)
      end
      raise Error.new(:too_many_redirects, "more than #{MAX_REDIRECTS} redirects from #{uri.host}")
    end

    def check_location!(uri, kind)
      allowed = case kind
      when :catalog then @policy.allowed_catalog?(uri)
      when :artifact then @policy.allowed_artifact?(uri)
      else @policy.allowed_redirect?(uri)
      end
      raise Error.new(:untrusted_location, "refused a request to #{uri.host}") unless allowed
    end

    def next_location(current, location)
      if location.blank? || location.length > MAX_LOCATION_LENGTH
        raise Error.new(:bad_redirect, "unusable redirect from #{current.host}")
      end

      current.merge(location)
    rescue URI::Error
      raise Error.new(:bad_redirect, "unusable redirect from #{current.host}")
    end

    # Returns the received byte count, or the Location of a redirect.
    def request(uri, max_bytes:, expires:, accept:, &block)
      endpoint = OutboundUrlGuard.validate!(uri.to_s, allow_private: @policy.allow_private_network?)
      result = nil
      Net::HTTP.start(endpoint.host, endpoint.port, use_ssl: true, ipaddr: endpoint.ipaddr,
        verify_mode: OpenSSL::SSL::VERIFY_PEER, open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        http.request(build_request(endpoint.uri, accept)) do |response|
          result = handle(response, uri, max_bytes: max_bytes, expires: expires, &block)
        end
      end
      result
    rescue OutboundUrlGuard::BlockedUrlError
      raise Error.new(:untrusted_location, "refused to contact #{uri.host}")
    rescue OpenSSL::SSL::SSLError
      raise Error.new(:tls, "could not establish trusted HTTPS with #{uri.host}")
    rescue *NETWORK_ERRORS => e
      raise Error.new(:network, "could not reach #{uri.host} (#{e.class.name})")
    end

    def build_request(uri, accept)
      # Passing Accept-Encoding up front also stops Net::HTTP from decoding:
      # the cache must hold exactly the publisher's bytes.
      Net::HTTP::Get.new(uri.request_uri, {
        "Accept" => accept, "Accept-Encoding" => "identity", "User-Agent" => USER_AGENT
      })
    end

    def handle(response, uri, max_bytes:, expires:)
      code = response.code.to_i
      return response["Location"].to_s if REDIRECT_CODES.include?(code)
      raise Error.new(:http_status, "#{uri.host} answered HTTP #{code}") unless code == 200

      encoding = response["Content-Encoding"].to_s.strip.downcase
      raise Error.new(:content_encoding, "#{uri.host} sent encoded content") unless encoding.empty? || encoding == "identity"

      declared = response["Content-Length"]
      if declared.present? && declared.to_i > max_bytes
        raise Error.new(:too_large, "#{uri.host} offered more than #{max_bytes} bytes")
      end

      received = 0
      response.read_body do |chunk|
        raise Error.new(:timeout, "#{uri.host} took too long") if monotonic > expires

        received += chunk.bytesize
        raise Error.new(:too_large, "#{uri.host} sent more than #{max_bytes} bytes") if received > max_bytes

        yield chunk
      end
      received
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
