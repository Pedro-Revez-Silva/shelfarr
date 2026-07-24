# frozen_string_literal: true

require "uri"

# Client for interacting with FlareSolverr to bypass DDoS protection
# https://github.com/FlareSolverr/FlareSolverr
class FlaresolverrClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class TimeoutError < Error; end
  MAX_RESPONSE_BYTES = 12.megabytes
  MAX_RESPONSE_DURATION = 2.minutes
  HttpResponse = Data.define(:status, :body)

  class << self
    # Check if FlareSolverr is configured
    def configured?
      SettingsService.flaresolverr_configured?
    end

    # Perform a GET request through FlareSolverr
    # Returns the HTML content of the page
    def get(url, timeout: 60000)
      ensure_configured!

      target = URI.parse(url.to_s)
      Rails.logger.info "[FlaresolverrClient] Requesting #{target.scheme}://#{target.host}"

      response = capped_post(
        cmd: "request.get",
        url: url,
        maxTimeout: timeout
      )

      Rails.logger.debug "[FlaresolverrClient] Raw response status: #{response.status}"
      Rails.logger.debug "[FlaresolverrClient] Raw response body length: #{response.body&.length || 0}"
      raise Error, "FlareSolverr returned HTTP #{response.status}" unless response.status == 200

      if response.body.blank?
        raise Error, "FlareSolverr returned empty response"
      end

      data = JSON.parse(response.body)
      raise Error, "FlareSolverr returned an invalid response" unless data.is_a?(Hash)
      Rails.logger.debug "[FlaresolverrClient] Parsed status: #{data['status']}, message: #{data['message']}"

      if data["status"] != "ok"
        error_message = data["message"] || "Unknown FlareSolverr error"
        Rails.logger.error "[FlaresolverrClient] Error: #{error_message}"
        raise Error, error_message
      end

      solution = data["solution"]
      unless solution.is_a?(Hash)
        Rails.logger.error "[FlaresolverrClient] No solution in response: #{data.keys}"
        raise Error, "FlareSolverr response missing solution"
      end

      final_url = solution["url"]
      final_target = URI.parse(final_url.to_s)
      unless final_target.scheme == "https" && final_target.host == target.host && final_target.port == target.port
        raise Error, "FlareSolverr navigated outside the requested HTTPS origin"
      end

      Rails.logger.info "[FlaresolverrClient] Success - Status: #{solution['status']}"

      html_content = solution["response"]
      unless html_content.is_a?(String) && html_content.present?
        Rails.logger.error "[FlaresolverrClient] Solution has no response content. Keys: #{solution.keys}"
        raise Error, "FlareSolverr solution has no HTML content"
      end

      Rails.logger.info "[FlaresolverrClient] Got HTML response: #{html_content.length} bytes"
      html_content
    rescue Faraday::ConnectionFailed => e
      Rails.logger.error "[FlaresolverrClient] Connection failed: #{e.message}"
      raise ConnectionError, "Failed to connect to FlareSolverr: #{e.message}"
    rescue Faraday::TimeoutError => e
      Rails.logger.error "[FlaresolverrClient] Timeout: #{e.message}"
      raise TimeoutError, "FlareSolverr request timed out: #{e.message}"
    rescue JSON::ParserError => e
      Rails.logger.error "[FlaresolverrClient] JSON parse error: #{e.message}"
      raise Error, "Failed to parse FlareSolverr response: #{e.message}"
    rescue URI::Error => e
      raise Error, "FlareSolverr returned an invalid URL: #{e.message}"
    end

    # Test connection to FlareSolverr
    def test_connection
      ensure_configured!

      endpoint = URI.parse(base_url)
      Rails.logger.info "[FlaresolverrClient] Testing connection to #{endpoint.scheme}://#{endpoint.host}"

      # Test by fetching a simple page
      response = capped_post(
        cmd: "request.get",
        url: "https://example.com",
        maxTimeout: 30000
      )

      return false unless response.status == 200

      data = JSON.parse(response.body)
      return false unless data.is_a?(Hash)

      success = data["status"] == "ok"
      Rails.logger.info "[FlaresolverrClient] Test connection result: #{success ? 'OK' : 'FAILED'} - #{data['message']}"
      success
    rescue Error, Faraday::Error, JSON::ParserError, URI::Error => e
      Rails.logger.error "[FlaresolverrClient] Test connection error: #{e.class} - #{e.message}"
      false
    end

    # Reset connection (useful when settings change)
    def reset_connection!
      @connection = nil
    end

    private

    def ensure_configured!
      unless configured?
        raise Error, "FlareSolverr is not configured"
      end
    end

    def capped_post(payload)
      body = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + MAX_RESPONSE_DURATION
      response = connection.post("/v1") do |request|
        request.body = payload.to_json
        request.options.on_data = lambda do |chunk, total_bytes, _env|
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            raise TimeoutError, "FlareSolverr response exceeded its time limit"
          end
          raise Error, "FlareSolverr response is too large" if total_bytes > MAX_RESPONSE_BYTES

          body << chunk
        end
      end
      body = response.body.to_s if body.empty? && response.body.present?
      raise Error, "FlareSolverr response is too large" if body.bytesize > MAX_RESPONSE_BYTES

      HttpResponse.new(status: response.status, body: body)
    end

    def connection
      @connection ||= Faraday.new(url: base_url) do |f|
        f.request :json
        f.adapter Faraday.default_adapter
        f.headers["Content-Type"] = "application/json"
        f.options.timeout = 120
        f.options.open_timeout = 10
      end
    end

    def base_url
      url = SettingsService.get(:flaresolverr_url).to_s.strip
      # Remove trailing slash and /v1 suffix if present (we add /v1 in requests)
      url = url.chomp("/")
      url = url.chomp("/v1")
      url
    end
  end
end
