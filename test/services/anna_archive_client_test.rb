# frozen_string_literal: true

require "test_helper"

class AnnaArchiveClientTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:anna_archive_enabled, true)
    SettingsService.set(:anna_archive_url, "https://annas-archive.org")
    SettingsService.set(:anna_archive_api_key, "test-api-key")
  end

  teardown do
    SettingsService.set(:anna_archive_enabled, false)
    SettingsService.set(:anna_archive_api_key, "")
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

  test "test_connection returns false when site is unreachable" do
    VCR.turned_off do
      stub_request(:get, "https://annas-archive.org/")
        .to_raise(Faraday::ConnectionFailed.new("Connection failed"))

      assert_not AnnaArchiveClient.test_connection
    end
  end

  private

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
