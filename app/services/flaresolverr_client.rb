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

      response = connection.post("/v1") do |req|
        req.body = {
          cmd: "request.get",
          url: url,
          maxTimeout: timeout
        }.to_json
      end

      data = JSON.parse(response.body)

      if data["status"] != "ok"
        error_message = data["message"] || "Unknown FlareSolverr error"
        Rails.logger.error "[FlaresolverrClient] Error: #{error_message}"
        raise Error, error_message
      end

      solution = data["solution"]
      Rails.logger.info "[FlaresolverrClient] Success - Status: #{solution['status']}"

      solution["response"]
    rescue Faraday::ConnectionFailed => e
      raise ConnectionError, "Failed to connect to FlareSolverr: #{e.message}"
    rescue Faraday::TimeoutError => e
      raise TimeoutError, "FlareSolverr request timed out: #{e.message}"
    rescue JSON::ParserError => e
      raise Error, "Failed to parse FlareSolverr response: #{e.message}"
    end

    # Test connection to FlareSolverr
    def test_connection
      ensure_configured!

      # Test by fetching a simple page
      response = connection.post("/v1") do |req|
        req.body = {
          cmd: "request.get",
          url: "https://example.com",
          maxTimeout: 30000
        }.to_json
      end

      data = JSON.parse(response.body)
      data["status"] == "ok"
    rescue Error, Faraday::Error, JSON::ParserError
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
      SettingsService.get(:flaresolverr_url)
    end
  end
end
