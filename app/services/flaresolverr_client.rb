# frozen_string_literal: true

# Client for interacting with FlareSolverr to bypass DDoS protection
# https://github.com/FlareSolverr/FlareSolverr
class FlaresolverrClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class TimeoutError < Error; end

  class << self
    # Check if FlareSolverr is configured
    def configured?
      SettingsService.flaresolverr_configured?
    end

    # Perform a GET request through FlareSolverr
    # Returns the HTML content of the page
    def get(url, timeout: 60000)
      ensure_configured!

      Rails.logger.info "[FlaresolverrClient] Requesting: #{url}"
      Rails.logger.info "[FlaresolverrClient] FlareSolverr URL: #{base_url}"

      response = connection.post("/v1") do |req|
        req.body = {
          cmd: "request.get",
          url: url,
          maxTimeout: timeout
        }.to_json
      end

      Rails.logger.debug "[FlaresolverrClient] Raw response status: #{response.status}"
      Rails.logger.debug "[FlaresolverrClient] Raw response body length: #{response.body&.length || 0}"

      if response.body.blank?
        raise Error, "FlareSolverr returned empty response"
      end

      data = JSON.parse(response.body)
      Rails.logger.debug "[FlaresolverrClient] Parsed status: #{data['status']}, message: #{data['message']}"

      if data["status"] != "ok"
        error_message = data["message"] || "Unknown FlareSolverr error"
        Rails.logger.error "[FlaresolverrClient] Error: #{error_message}"
        raise Error, error_message
      end

      solution = data["solution"]
      if solution.nil?
        Rails.logger.error "[FlaresolverrClient] No solution in response: #{data.keys}"
        raise Error, "FlareSolverr response missing solution"
      end

      Rails.logger.info "[FlaresolverrClient] Success - Status: #{solution['status']}, URL: #{solution['url']}"

      html_content = solution["response"]
      if html_content.blank?
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
    end

    # Test connection to FlareSolverr
    def test_connection
      ensure_configured!

      Rails.logger.info "[FlaresolverrClient] Testing connection to: #{base_url}"

      # Test by fetching a simple page
      response = connection.post("/v1") do |req|
        req.body = {
          cmd: "request.get",
          url: "https://example.com",
          maxTimeout: 30000
        }.to_json
      end

      data = JSON.parse(response.body)
      success = data["status"] == "ok"
      Rails.logger.info "[FlaresolverrClient] Test connection result: #{success ? 'OK' : 'FAILED'} - #{data['message']}"
      success
    rescue Error, Faraday::Error, JSON::ParserError => e
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
