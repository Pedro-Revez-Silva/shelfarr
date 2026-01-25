# frozen_string_literal: true

require "test_helper"

class FlaresolverrClientTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:flaresolverr_url, "http://localhost:8191")
  end

  teardown do
    SettingsService.set(:flaresolverr_url, "")
    FlaresolverrClient.reset_connection!
  end

  test "configured? returns true when URL is set" do
    assert FlaresolverrClient.configured?
  end

  test "configured? returns false when URL is empty" do
    SettingsService.set(:flaresolverr_url, "")
    assert_not FlaresolverrClient.configured?
  end

  test "get raises error when not configured" do
    SettingsService.set(:flaresolverr_url, "")

    assert_raises FlaresolverrClient::Error do
      FlaresolverrClient.get("https://example.com")
    end
  end

  test "get returns HTML content on success" do
    VCR.turned_off do
      stub_flaresolverr_success

      html = FlaresolverrClient.get("https://example.com")

      assert_equal "<html>Test content</html>", html
    end
  end

  test "get raises Error on FlareSolverr error response" do
    VCR.turned_off do
      stub_flaresolverr_error("Challenge failed")

      error = assert_raises FlaresolverrClient::Error do
        FlaresolverrClient.get("https://example.com")
      end

      assert_equal "Challenge failed", error.message
    end
  end

  test "get raises ConnectionError on connection failure" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:8191/v1")
        .to_raise(Faraday::ConnectionFailed.new("Connection refused"))

      assert_raises FlaresolverrClient::ConnectionError do
        FlaresolverrClient.get("https://example.com")
      end
    end
  end

  test "get raises TimeoutError on timeout" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:8191/v1")
        .to_raise(Faraday::TimeoutError.new("Request timed out"))

      assert_raises FlaresolverrClient::TimeoutError do
        FlaresolverrClient.get("https://example.com")
      end
    end
  end

  test "test_connection returns true on success" do
    VCR.turned_off do
      stub_flaresolverr_success

      assert FlaresolverrClient.test_connection
    end
  end

  test "test_connection returns false on error" do
    VCR.turned_off do
      stub_request(:post, "http://localhost:8191/v1")
        .to_raise(Faraday::ConnectionFailed.new("Connection refused"))

      assert_not FlaresolverrClient.test_connection
    end
  end

  private

  def stub_flaresolverr_success
    stub_request(:post, "http://localhost:8191/v1")
      .with(
        body: hash_including("cmd" => "request.get"),
        headers: { "Content-Type" => "application/json" }
      )
      .to_return(
        status: 200,
        body: {
          status: "ok",
          message: "",
          solution: {
            status: 200,
            response: "<html>Test content</html>"
          }
        }.to_json
      )
  end

  def stub_flaresolverr_error(message)
    stub_request(:post, "http://localhost:8191/v1")
      .to_return(
        status: 200,
        body: {
          status: "error",
          message: message
        }.to_json
      )
  end
end
