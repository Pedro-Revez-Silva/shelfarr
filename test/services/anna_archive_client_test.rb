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

  test "search uses repeated filters and keeps only requested audiobook archives" do
    html = <<~HTML
      <html>
        <body>
          <form class="js-search-form">
            <div class="js-aarecord-list-outer">
              <div><h3>Ebook Result With A Descriptive Title</h3><a href="/md5/eb00123">Details</a><span class="badge">epub</span><span>5 MB English 2024</span></div>
              <div><h3>Audiobook Result With A Descriptive Title</h3><a href="/md5/a0d10123">Details</a><span class="badge">zip</span><span>500 MB English 2024</span></div>
            </div>
          </form>
        </body>
      </html>
    HTML

    VCR.turned_off do
      search_request = stub_request(:get, /annas-archive\.org\/search/)
        .with do |request|
          pairs = URI.decode_www_form(request.uri.query.to_s)
          pairs.select { |key, _| key == "ext" }.map(&:last) == [ "zip" ] &&
            pairs.none? { |key, _| key == "content" }
        end
        .to_return(status: 200, body: html)

      results = AnnaArchiveClient.search(
        "test audiobook",
        file_types: AnnaArchiveClient::AUDIOBOOK_FILE_TYPES,
        content_types: []
      )

      assert_requested search_request
      assert_equal 1, results.size
      assert_equal "a0d10123", results.first.md5
      assert_equal "zip", results.first.file_type
    end
  end

  test "search excludes Anna's Archive partial matches when primary results are empty" do
    html = <<~HTML
      <html>
        <body>
          <form class="js-search-form">
            <div class="js-aarecord-list-outer"></div>
            <div class="js-partial-matches-show hidden">
              <div class="js-aarecord-list-outer">
                <div><h3>Related Audiobook With A Descriptive Title</h3><a href="/md5/fa111123">Details</a><span class="badge">zip</span><span>500 MB English 2024</span></div>
              </div>
            </div>
          </form>
        </body>
      </html>
    HTML

    VCR.turned_off do
      stub_request(:get, /annas-archive\.org\/search/).to_return(status: 200, body: html)

      results = AnnaArchiveClient.search(
        "missing audiobook",
        file_types: AnnaArchiveClient::AUDIOBOOK_FILE_TYPES,
        content_types: []
      )

      assert_empty results
    end
  end

  test "search serializes multiple ebook and content filters as repeated parameters" do
    url = AnnaArchiveClient.send(
      :build_search_url,
      "test book",
      AnnaArchiveClient::EBOOK_FILE_TYPES,
      content_types: AnnaArchiveClient::BOOK_CONTENT_TYPES,
      language: "en"
    )
    pairs = URI.decode_www_form(URI.parse(url).query)

    assert_equal %w[epub pdf], pairs.select { |key, _| key == "ext" }.map(&:last)
    assert_equal AnnaArchiveClient::BOOK_CONTENT_TYPES, pairs.select { |key, _| key == "content" }.map(&:last)
    assert_includes pairs, [ "lang", "en" ]
  end

  test "language extraction does not treat embedded two-letter codes as languages" do
    french = Nokogiri::HTML.fragment(<<~HTML).at_css("div")
      <div>
        <h3>The English Patient Audiobook</h3>
        <span>500 MB French 2024</span>
      </div>
    HTML
    multilingual = Nokogiri::HTML.fragment(<<~HTML).at_css("div")
      <div>
        <h3>English Lessons</h3>
        <div class="text-gray-800 font-semibold text-sm mt-2">Portuguese [pt] · English [en] · ZIP · 500 MB</div>
      </div>
    HTML
    dutch = Nokogiri::HTML.fragment(<<~HTML).at_css("div")
      <div><div class="text-gray-800 font-semibold text-sm mt-2">Dutch [nl] · ZIP · 500 MB</div></div>
    HTML
    brazilian_portuguese = Nokogiri::HTML.fragment(<<~HTML).at_css("div")
      <div><div class="text-gray-800 font-semibold text-sm mt-2">Portuguese (Brazil) [pt-BR] · ZIP · 500 MB</div></div>
    HTML

    assert_equal "fr", AnnaArchiveClient.send(:extract_language, french)
    assert_equal "pt", AnnaArchiveClient.send(:extract_language, multilingual)
    assert_equal "en", AnnaArchiveClient.send(:extract_language, multilingual, preferred_language: "en")
    assert_equal "nl", AnnaArchiveClient.send(:extract_language, dutch)
    assert_equal "pt-BR", AnnaArchiveClient.send(:extract_language, brazilian_portuguese)
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

  test "search stops mirror rotation when its continuation is cancelled" do
    VCR.turned_off do
      SettingsService.set(:anna_archive_url, "https://offline.example\nhttps://annas-archive.org")
      continuation_checks = 0
      after_attempt = lambda do
        continuation_checks += 1
        false
      end

      stub_request(:get, /offline\.example\/search/)
        .to_raise(Faraday::ConnectionFailed.new("Connection failed"))
      second_mirror = stub_request(:get, /annas-archive\.org\/search/)

      assert_raises AnnaArchiveClient::SearchCancelled do
        AnnaArchiveClient.search("test book", after_attempt: after_attempt)
      end

      assert_equal 1, continuation_checks
      assert_requested :get, /offline\.example\/search/
      assert_not_requested second_mirror
    end
  end

  test "search tries next configured URL when first URL has an incompatible search page" do
    VCR.turned_off do
      SettingsService.set(:anna_archive_url, "https://incompatible.example\nhttps://annas-archive.org")

      stub_request(:get, /incompatible\.example\/search/)
        .to_return(status: 200, body: '<html><form action="/s/"></form></html>')
      stub_anna_search_with_results

      results = AnnaArchiveClient.search("test book")

      assert_equal "abc123def456", results.first.md5
      assert_requested :get, /incompatible\.example\/search/
      assert_requested :get, /annas-archive\.org\/search/
    end
  end

  test "search raises IncompatibleSiteError for a successful non-Anna response" do
    VCR.turned_off do
      stub_request(:get, /annas-archive\.org\/search/)
        .to_return(status: 200, body: '<html><form action="/s/"></form><p>404 Page not found</p></html>')

      error = assert_raises AnnaArchiveClient::IncompatibleSiteError do
        AnnaArchiveClient.search("test query")
      end

      assert_includes error.message, "compatible Anna's Archive /search interface"
    end
  end

  test "search accepts a compatible page with no results" do
    VCR.turned_off do
      stub_request(:get, /annas-archive\.org\/search/)
        .to_return(status: 200, body: anna_search_page_without_results)

      assert_empty AnnaArchiveClient.search("missing book")
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

  test "test_connection returns true when search interface is compatible" do
    VCR.turned_off do
      stub_request(:get, "https://annas-archive.org/search?q=shelfarr")
        .to_return(status: 200, body: anna_search_page_without_results)

      assert AnnaArchiveClient.test_connection
    end
  end

  test "test_connection tries configured URLs until one is reachable" do
    VCR.turned_off do
      SettingsService.set(:anna_archive_url, "https://offline.example\nhttps://annas-archive.org")

      stub_request(:get, "https://offline.example/search?q=shelfarr")
        .to_raise(Faraday::ConnectionFailed.new("Connection failed"))
      stub_request(:get, "https://annas-archive.org/search?q=shelfarr")
        .to_return(status: 200, body: anna_search_page_without_results)

      assert AnnaArchiveClient.test_connection
      assert_requested :get, "https://offline.example/search?q=shelfarr"
      assert_requested :get, "https://annas-archive.org/search?q=shelfarr"
    end
  end

  test "test_connection returns false when site is unreachable" do
    VCR.turned_off do
      stub_request(:get, "https://annas-archive.org/search?q=shelfarr")
        .to_raise(Faraday::ConnectionFailed.new("Connection failed"))

      assert_not AnnaArchiveClient.test_connection
    end
  end

  test "test_connection returns false when homepage-like HTML is incompatible" do
    VCR.turned_off do
      stub_request(:get, "https://annas-archive.org/search?q=shelfarr")
        .to_return(status: 200, body: "<html><body>Not Anna's Archive</body></html>")

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

  def anna_search_page_without_results
    <<~HTML
      <html>
        <body>
          <form action="/search">
            <input name="q">
          </form>
          <p>No files found.</p>
        </body>
      </html>
    HTML
  end

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
