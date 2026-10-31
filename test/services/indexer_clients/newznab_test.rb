# frozen_string_literal: true

require "test_helper"

class IndexerClients::NewznabTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:newznab_url, "http://localhost:5076")
    SettingsService.set(:newznab_api_key, "newznab-api-key")
  end

  teardown do
    IndexerClients::Newznab.reset_connection!
  end

  test "configured? returns true when newznab credentials are present" do
    assert IndexerClients::Newznab.configured?
  end

  test "search parses newznab xml results" do
    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/">
        <channel>
          <item>
            <title>Test Newznab Result</title>
            <guid>newznab-guid-123</guid>
            <link>https://example.com/details/123</link>
            <pubDate>Mon, 01 Jan 2024 12:00:00 GMT</pubDate>
            <enclosure url="http://localhost:5076/getnzb/api/123?apikey=newznab-api-key" length="1048576" type="application/x-nzb" />
            <newznab:attr name="hydraIndexerName" value="NZBHydra Books" />
            <newznab:attr name="category" value="7030" />
            <newznab:attr name="size" value="1048576" />
          </item>
        </channel>
      </rss>
    XML

    VCR.turned_off do
      stub_request(:get, "http://localhost:5076/api")
        .with(query: hash_including("apikey" => "newznab-api-key", "t" => "search", "cat" => "7020,7000"))
        .to_return(status: 200, body: body, headers: { "Content-Type" => "application/xml" })

      results = IndexerClients::Newznab.search("test query", book_type: :ebook)

      assert_equal 1, results.size
      result = results.first
      assert_equal "newznab-guid-123", result.guid
      assert_equal "Test Newznab Result", result.title
      assert_equal "NZBHydra Books", result.indexer
      assert_equal 1_048_576, result.size_bytes
      assert_nil result.seeders
      assert_equal "http://localhost:5076/getnzb/api/123?apikey=newznab-api-key", result.download_url
      assert_nil result.magnet_url
      assert_equal [ 7030 ], result.category_ids
    end
  end

  test "accepts configured URL that already points at the api endpoint" do
    SettingsService.set(:newznab_url, "http://localhost:5076/api")
    IndexerClients::Newznab.reset_connection!

    VCR.turned_off do
      stub_request(:get, "http://localhost:5076/api")
        .with(query: hash_including("apikey" => "newznab-api-key", "t" => "caps"))
        .to_return(status: 200, body: "<caps />", headers: { "Content-Type" => "application/xml" })

      assert IndexerClients::Newznab.test_connection
    end
  end

  # The jobs process never sees the web process's reset_all_connections!.
  test "search uses the corrected Newznab URL without resetting the connection" do
    SettingsService.set(:newznab_url, "http://old-newznab.example:5076")
    SettingsService.set(:newznab_api_key, "old-newznab-key")
    IndexerClients::Newznab.reset_connection!

    VCR.turned_off do
      stub_request(:get, "http://old-newznab.example:5076/api")
        .with(query: hash_including("apikey" => "old-newznab-key", "t" => "caps"))
        .to_return(status: 200, body: "<caps />", headers: { "Content-Type" => "application/xml" })

      assert IndexerClients::Newznab.test_connection

      SettingsService.set(:newznab_url, "http://new-newznab.example:5076/api")
      SettingsService.set(:newznab_api_key, "new-newznab-key")

      search = stub_request(:get, "http://new-newznab.example:5076/api")
        .with(query: hash_including("apikey" => "new-newznab-key", "t" => "search"))
        .to_return(
          status: 200,
          body: "<rss><channel></channel></rss>",
          headers: { "Content-Type" => "application/xml" }
        )

      assert_empty IndexerClients::Newznab.search("test", book_type: :ebook)
      assert_requested search, times: 1
      assert_not_requested :get, %r{old-newznab\.example.+t=search}
    end
  end

  # The jobs process never sees the web process's reset_all_connections!.
  test "search drops the cached connection after the Newznab API key is removed" do
    IndexerClients::Newznab.reset_connection!

    VCR.turned_off do
      stub_request(:get, "http://localhost:5076/api")
        .with(query: hash_including("apikey" => "newznab-api-key", "t" => "caps"))
        .to_return(status: 200, body: "<caps />", headers: { "Content-Type" => "application/xml" })

      assert IndexerClients::Newznab.test_connection

      SettingsService.set(:newznab_api_key, "")

      error = assert_raises IndexerClients::Newznab::NotConfiguredError do
        IndexerClients::Newznab.search("test", book_type: :ebook)
      end
      assert_equal "Newznab is not configured", error.message
      assert_raises IndexerClients::Newznab::NotConfiguredError do
        IndexerClients::Newznab.send(:connection)
      end
      assert_requested :get, "http://localhost:5076/api", query: hash_including("t" => "caps"), times: 1
      assert_not_requested :get, "http://localhost:5076/api", query: hash_including("t" => "search")
      assert_nil IndexerClients::Newznab.instance_variable_get(:@connection)
      assert_nil IndexerClients::Newznab.instance_variable_get(:@connection_settings_key)
    end
  end

  test "preserves reverse proxy subpath when configured URL ends with api" do
    SettingsService.set(:newznab_url, "http://localhost:5076/nzbhydra2/api")
    IndexerClients::Newznab.reset_connection!

    VCR.turned_off do
      stub_request(:get, "http://localhost:5076/nzbhydra2/api")
        .with(query: hash_including("apikey" => "newznab-api-key", "t" => "caps"))
        .to_return(status: 200, body: "<caps />", headers: { "Content-Type" => "application/xml" })

      assert IndexerClients::Newznab.test_connection
    end
  end
end
