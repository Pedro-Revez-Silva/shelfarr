# frozen_string_literal: true

require "test_helper"

class AnnaArchiveClientTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:anna_archive_enabled, true)
    SettingsService.set(:anna_archive_url, "https://annas-archive.org")
    SettingsService.set(:anna_archive_api_key, "test-api-key")
    SettingsService.set(:flaresolverr_url, "")
    AnnaArchiveClient.reset_connection!
  end

  teardown do
    SettingsService.set(:anna_archive_enabled, false)
    SettingsService.set(:anna_archive_api_key, "")
    SettingsService.set(:flaresolverr_url, "")
    AnnaArchiveClient.reset_connection!
  end

  test "configured? returns true when enabled and key is set" do
    assert AnnaArchiveClient.configured?
  end

  test "configured? returns false when not enabled" do
    SettingsService.set(:anna_archive_enabled, false)
    assert_not AnnaArchiveClient.configured?
  end

  test "configured? returns false when key is empty" do
    SettingsService.set(:anna_archive_api_key, "")
    assert_not AnnaArchiveClient.configured?
  end

  test "enabled? returns true when setting is enabled" do
    assert AnnaArchiveClient.enabled?
  end

  test "enabled? returns false when setting is disabled" do
    SettingsService.set(:anna_archive_enabled, false)
    assert_not AnnaArchiveClient.enabled?
  end

  test "search raises NotConfiguredError when not configured" do
    SettingsService.set(:anna_archive_enabled, false)

    assert_raises AnnaArchiveClient::NotConfiguredError do
      AnnaArchiveClient.search("test query")
    end
  end

  test "search parses HTML results" do
    VCR.turned_off do
      stub_anna_search_with_results

      results = AnnaArchiveClient.search("test book")

      assert results.is_a?(Array)
      assert results.any?
      assert_equal "abc123def456", results.first.md5
      assert_equal "Test Book Title", results.first.title
    end
  end

  test "search tries next configured URL when first URL fails" do
    VCR.turned_off do
      SettingsService.set(:anna_archive_url, "https://offline.example\nhttps://annas-archive.org")

      stub_request(:get, /offline\.example\/search/)
        .to_raise(Faraday::ConnectionFailed.new("Connection failed"))
      stub_anna_search_with_results

      results = AnnaArchiveClient.search("test book")

      assert_equal "abc123def456", results.first.md5
      assert_requested :get, /offline\.example\/search/
      assert_requested :get, /annas-archive\.org\/search/
    end
  end

  test "search returns empty array on connection error" do
    VCR.turned_off do
      stub_request(:get, /annas-archive\.org\/search/)
        .to_raise(Faraday::ConnectionFailed.new("Connection failed"))

      assert_raises AnnaArchiveClient::ConnectionError do
        AnnaArchiveClient.search("test query")
      end
    end
  end

  test "get_download_url returns URL from API" do
    VCR.turned_off do
      stub_anna_download_api

      url = AnnaArchiveClient.get_download_url("abc123def456")

      assert_equal "magnet:?xt=urn:btih:abc123def456", url
    end
  end

  test "get_download_url tries next configured URL when first API URL fails" do
    VCR.turned_off do
      SettingsService.set(:anna_archive_url, "https://offline.example, https://annas-archive.org")

      stub_request(:get, /offline\.example\/dyn\/api\/fast_download\.json/)
        .to_raise(Faraday::ConnectionFailed.new("Connection failed"))
      stub_anna_download_api

      url = AnnaArchiveClient.get_download_url("abc123def456")

      assert_equal "magnet:?xt=urn:btih:abc123def456", url
      assert_requested :get, /offline\.example\/dyn\/api\/fast_download\.json/
      assert_requested :get, /annas-archive\.org\/dyn\/api\/fast_download\.json/
    end
  end

  test "get_download_url raises error on API error" do
    VCR.turned_off do
      stub_request(:get, /annas-archive\.org\/dyn\/api\/fast_download\.json/)
        .to_return(
          status: 200,
          body: { error: "Invalid md5" }.to_json
        )

      assert_raises AnnaArchiveClient::Error do
        AnnaArchiveClient.get_download_url("invalid")
      end
    end
  end

  test "test_connection returns true when site is reachable" do
    VCR.turned_off do
      stub_request(:get, "https://annas-archive.org/")
        .to_return(status: 200, body: "<html></html>")

      assert AnnaArchiveClient.test_connection
    end
  end

  test "test_connection tries configured URLs until one is reachable" do
    VCR.turned_off do
      SettingsService.set(:anna_archive_url, "https://offline.example\nhttps://annas-archive.org")

      stub_request(:get, "https://offline.example/")
        .to_raise(Faraday::ConnectionFailed.new("Connection failed"))
      stub_request(:get, "https://annas-archive.org/")
        .to_return(status: 200, body: "<html></html>")

      assert AnnaArchiveClient.test_connection
      assert_requested :get, "https://offline.example/"
      assert_requested :get, "https://annas-archive.org/"
    end
  end

  test "test_connection returns false when site is unreachable" do
    VCR.turned_off do
      stub_request(:get, "https://annas-archive.org/")
        .to_raise(Faraday::ConnectionFailed.new("Connection failed"))

      assert_not AnnaArchiveClient.test_connection
    end
  end

  test "search raises BotProtectionError on 403 response" do
    VCR.turned_off do
      stub_request(:get, /annas-archive\.org\/search/)
        .to_return(status: 403, body: "Forbidden")

      error = assert_raises AnnaArchiveClient::BotProtectionError do
        AnnaArchiveClient.search("test query")
      end

      assert_includes error.message, "FlareSolverr"
    end
  end

  test "search raises BotProtectionError when DDoS-Guard detected" do
    VCR.turned_off do
      stub_request(:get, /annas-archive\.org\/search/)
        .to_return(status: 200, body: "<html>DDoS-Guard protection</html>")

      error = assert_raises AnnaArchiveClient::BotProtectionError do
        AnnaArchiveClient.search("test query")
      end

      assert_includes error.message, "FlareSolverr"
    end
  end

  test "search preserves BotProtectionError when later configured URLs fail" do
    VCR.turned_off do
      SettingsService.set(:anna_archive_url, "https://annas-archive.org\nhttps://offline.example")

      stub_request(:get, /annas-archive\.org\/search/)
        .to_return(status: 403, body: "Forbidden")
      stub_request(:get, /offline\.example\/search/)
        .to_raise(Faraday::ConnectionFailed.new("Connection failed"))

      error = assert_raises AnnaArchiveClient::BotProtectionError do
        AnnaArchiveClient.search("test query")
      end

      assert_includes error.message, "FlareSolverr"
      assert_requested :get, /annas-archive\.org\/search/
      assert_requested :get, /offline\.example\/search/
    end
  end

  test "search uses FlareSolverr when configured" do
    VCR.turned_off do
      SettingsService.set(:flaresolverr_url, "http://localhost:8191")

      stub_flaresolverr_with_search_results
      results = AnnaArchiveClient.search("test book")

      assert results.is_a?(Array)
      assert results.any?
      assert_equal "abc123def456", results.first.md5

      SettingsService.set(:flaresolverr_url, "")
    end
  end

  test "info_url uses the working Anna Archive URL" do
    VCR.turned_off do
      SettingsService.set(:anna_archive_url, "https://offline.example\nhttps://annas-archive.org")

      stub_request(:get, /offline\.example\/search/)
        .to_raise(Faraday::ConnectionFailed.new("Connection failed"))
      stub_anna_search_with_results

      AnnaArchiveClient.search("test book")

      assert_equal "https://annas-archive.org/md5/abc123def456", AnnaArchiveClient.info_url("abc123def456")
    end
  end

  private

  def stub_flaresolverr_with_search_results
    html = <<~HTML
      <html>
        <body>
          <a href="/md5/abc123def456">
            <div>
              <h3>Test Book Title</h3>
              <span class="author">by Test Author</span>
              <span class="badge">epub</span>
              <span>15.2 MB</span>
              <span>English</span>
              <span>2023</span>
            </div>
          </a>
        </body>
      </html>
    HTML

    stub_request(:post, "http://localhost:8191/v1")
      .to_return(
        status: 200,
        body: {
          status: "ok",
          message: "",
          solution: {
            status: 200,
            response: html
          }
        }.to_json
      )
  end

  def stub_anna_search_with_results
    html = <<~HTML
      <html>
        <body>
          <a href="/md5/abc123def456">
            <div>
              <h3>Test Book Title</h3>
              <span class="author">by Test Author</span>
              <span class="badge">epub</span>
              <span>15.2 MB</span>
              <span>English</span>
              <span>2023</span>
            </div>
          </a>
        </body>
      </html>
    HTML

    stub_request(:get, /annas-archive\.org\/search/)
      .to_return(status: 200, body: html)
  end

  def stub_anna_download_api
    stub_request(:get, /annas-archive\.org\/dyn\/api\/fast_download\.json/)
      .with(query: hash_including({ "md5" => "abc123def456", "key" => "test-api-key" }))
      .to_return(
        status: 200,
        body: { download_url: "magnet:?xt=urn:btih:abc123def456" }.to_json
      )
  end
end
