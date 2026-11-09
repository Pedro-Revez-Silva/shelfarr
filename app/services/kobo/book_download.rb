# frozen_string_literal: true

require "net/http"

module Kobo
  # Streams one signed Kobo download into an open file.
  #
  # The first request must go to Kobo's fixed HTTPS download host; it may
  # redirect only to Kobo's fixed HTTPS file host. No Authorization header,
  # cookie, environment proxy or caller-chosen host is ever used, so neither
  # account credentials nor Shelfarr secrets reach the download servers. The
  # signed URL is not logged and error messages carry only a category.
  class BookDownload
    START_HOST = DownloadRights::DOWNLOAD_HOST
    REDIRECT_HOSTS = %w[storedownloads.kobo.com getbook.kobo.com].freeze
    MAX_REDIRECTS = 3
    MAX_BYTES = KoboPublication::MAX_EPUB_BYTES
    MAX_SECONDS = 300
    USER_AGENT = HttpClient::USER_AGENT
    Result = Data.define(:bytes, :sha256)
    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @clock = clock
    end

    # Writes the body to +io+ and returns its size and SHA-256 digest. The
    # declared size (from Kobo's metadata or the response) must be known and
    # must match exactly, so a truncated transfer is never reported as complete.
    def call(url, io:, expected_size: nil)
      uri = parse(url)
      raise Error, "untrusted_host" unless uri.host == START_HOST

      deadline = @clock.call + MAX_SECONDS
      (MAX_REDIRECTS + 1).times do
        target = fetch(uri, io: io, expected_size: expected_size, deadline: deadline)
        return target if target.is_a?(Result)

        uri = target
      end
      raise Error, "download_refused"
    end

    private

    def parse(value)
      uri = URI.parse(value.to_s)
      raise Error, "untrusted_host" unless trusted?(uri)

      uri
    rescue URI::InvalidURIError
      raise Error, "untrusted_host"
    end

    def trusted?(uri)
      uri.is_a?(URI::HTTPS) && REDIRECT_HOSTS.include?(uri.host) && uri.port == 443 &&
        uri.userinfo.nil? && uri.fragment.nil? && uri.path.to_s.start_with?("/") &&
        !uri.to_s.match?(/[\x00-\x20\x7f\\]/)
    end

    def fetch(uri, io:, expected_size:, deadline:)
      request = Net::HTTP::Get.new(uri.request_uri, { "User-Agent" => USER_AGENT, "Accept" => "*/*", "Accept-Encoding" => "identity" })
      # Net::HTTP.new(host, port, nil) disables any environment proxy.
      http = Net::HTTP.new(uri.host, 443, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 10
      http.read_timeout = 30
      http.write_timeout = 10
      http.max_retries = 0
      http.start do |connection|
        connection.request(request) do |response|
          code = response.code.to_i
          if [ 301, 302, 303, 307, 308 ].include?(code)
            location = response["location"].to_s
            raise Error, "download_refused" if location.empty? || location.bytesize > DownloadRights::MAX_URL_BYTES

            begin
              return parse(URI.join(uri, location).to_s)
            rescue URI::Error, ArgumentError
              raise Error, "untrusted_host"
            end
          end
          raise Error, "provider_unavailable" if code == 429 || code >= 500
          raise Error, "download_refused" unless code == 200
          raise Error, "invalid_file" unless [ nil, "", "identity" ].include?(response["content-encoding"])

          declared = response["content-length"]
          declared = declared.to_s.match?(/\A\d{1,12}\z/) ? declared.to_i : nil
          raise Error, "incomplete" if declared && expected_size && declared != expected_size
          size = expected_size || declared
          raise Error, "incomplete" unless size
          raise Error, "too_large" if size > MAX_BYTES

          return Result.new(**stream(response, io: io, size: size, deadline: deadline))
        end
      end
    rescue Error
      raise
    rescue SocketError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, Net::ProtocolError, Net::HTTPBadResponse
      raise Error, "provider_unavailable"
    end

    def stream(response, io:, size:, deadline:)
      digest = Digest::SHA256.new
      bytes = 0
      response.read_body do |chunk|
        bytes += chunk.bytesize
        raise Error, "incomplete" if bytes > size
        raise Error, "timed_out" if @clock.call > deadline

        begin
          io.write(chunk)
        rescue Errno::ENOSPC, Errno::EDQUOT
          raise Error, "storage_full"
        end
        digest.update(chunk)
      end
      raise Error, "incomplete" unless bytes == size

      { bytes: bytes, sha256: digest.hexdigest }
    end
  end
end
