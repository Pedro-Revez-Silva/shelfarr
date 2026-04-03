# frozen_string_literal: true

require "test_helper"

class IndexerClients::JackettTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:jackett_url, "http://localhost:9117")
    SettingsService.set(:jackett_api_key, "jackett-api-key")
    SettingsService.set(:jackett_indexer_filter, "all")
  end

  teardown do
    IndexerClients::Jackett.reset_connection!
  end

  test "configured? returns true when jackett credentials are present" do
    assert IndexerClients::Jackett.configured?
  end

  test "search parses torznab xml results" do
    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
        <channel>
          <item>
            <title>Test Jackett Result</title>
            <guid>jackett-guid-123</guid>
            <link>https://example.com/details/123</link>
            <pubDate>Mon, 01 Jan 2024 12:00:00 GMT</pubDate>
            <jackettindexer>Books</jackettindexer>
            <enclosure url="magnet:?xt=urn:btih:123" length="1048576" type="application/x-bittorrent" />
            <torznab:attr name="seeders" value="42" />
            <torznab:attr name="peers" value="7" />
            <torznab:attr name="size" value="1048576" />
          </item>
        </channel>
      </rss>
    XML

    VCR.turned_off do
      stub_request(:get, %r{localhost:9117/api/v2\.0/indexers/all/results/torznab/api})
        .with(query: hash_including("apikey" => "jackett-api-key", "t" => "search"))
        .to_return(status: 200, body: body, headers: { "Content-Type" => "application/xml" })

      results = IndexerClients::Jackett.search("test query", book_type: :ebook)

      assert_equal 1, results.size
      result = results.first
      assert_equal "jackett-guid-123", result.guid
      assert_equal "Test Jackett Result", result.title
      assert_equal "Books", result.indexer
      assert_equal 42, result.seeders
      assert_equal 7, result.leechers
      assert_equal "magnet:?xt=urn:btih:123", result.magnet_url
      assert_equal "magnet:?xt=urn:btih:123", result.download_link
    end
  end

  test "test_connection returns true when caps request succeeds" do
    VCR.turned_off do
      stub_request(:get, %r{localhost:9117/api/v2\.0/indexers/all/results/torznab/api})
        .with(query: hash_including("apikey" => "jackett-api-key", "t" => "caps"))
        .to_return(status: 200, body: "<caps />", headers: { "Content-Type" => "application/xml" })

      assert IndexerClients::Jackett.test_connection
    end
  end
end
