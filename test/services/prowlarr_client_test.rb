# frozen_string_literal: true

require "test_helper"

class ProwlarrClientTest < ActiveSupport::TestCase
  setup do
    # Configure Prowlarr settings for tests
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-api-key-12345")
  end

  teardown do
    # Reset connection between tests
    ProwlarrClient.instance_variable_set(:@connection, nil)
  end

  test "configured? returns true when both url and api_key are set" do
    assert ProwlarrClient.configured?
  end

  test "configured? returns false when url is missing" do
    SettingsService.set(:prowlarr_url, "")
    assert_not ProwlarrClient.configured?
  end

  test "configured? returns false when api_key is missing" do
    SettingsService.set(:prowlarr_api_key, "")
    assert_not ProwlarrClient.configured?
  end

  test "search raises NotConfiguredError when not configured" do
    SettingsService.set(:prowlarr_api_key, "")

    assert_raises ProwlarrClient::NotConfiguredError do
      ProwlarrClient.search("test query")
    end
  end

  test "search returns array of Result objects" do
    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/search.*harry.*potter}i)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            {
              "guid" => "abc123",
              "title" => "Harry Potter Audiobook Collection",
              "indexer" => "TestIndexer",
              "size" => 1073741824,
              "seeders" => 50,
              "leechers" => 10,
              "downloadUrl" => "http://example.com/download/abc123",
              "magnetUrl" => "magnet:?xt=urn:btih:abc123",
              "infoUrl" => "http://example.com/info/abc123",
              "publishDate" => "2024-01-15T10:00:00Z"
            }
          ].to_json
        )

      results = ProwlarrClient.search("harry potter audiobook")

      assert_kind_of Array, results
      assert_equal 1, results.size

      result = results.first
      assert_kind_of ProwlarrClient::Result, result
      assert_equal "abc123", result.guid
      assert_equal "Harry Potter Audiobook Collection", result.title
      assert_equal "TestIndexer", result.indexer
      assert_equal 50, result.seeders
      assert_equal "magnet:?xt=urn:btih:abc123", result.download_link
    end
  end

  test "search handles empty results" do
    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      results = ProwlarrClient.search("xyznonexistent123456789")
      assert_equal [], results
    end
  end

  test "Result.downloadable? returns true with magnet_url" do
    result = ProwlarrClient::Result.new(
      guid: "test", title: "Test", indexer: "Test", size_bytes: 100,
      seeders: 10, leechers: 5, download_url: nil, magnet_url: "magnet:?xt=test",
      info_url: nil, published_at: nil
    )
    assert result.downloadable?
  end

  test "Result.downloadable? returns true with download_url" do
    result = ProwlarrClient::Result.new(
      guid: "test", title: "Test", indexer: "Test", size_bytes: 100,
      seeders: 10, leechers: 5, download_url: "http://example.com/download",
      magnet_url: nil, info_url: nil, published_at: nil
    )
    assert result.downloadable?
  end

  test "Result.downloadable? returns false without links" do
    result = ProwlarrClient::Result.new(
      guid: "test", title: "Test", indexer: "Test", size_bytes: 100,
      seeders: 10, leechers: 5, download_url: nil, magnet_url: nil,
      info_url: nil, published_at: nil
    )
    assert_not result.downloadable?
  end

  test "Result.download_link prefers magnet over download_url" do
    result = ProwlarrClient::Result.new(
      guid: "test", title: "Test", indexer: "Test", size_bytes: 100,
      seeders: 10, leechers: 5, download_url: "http://example.com/download",
      magnet_url: "magnet:?xt=test", info_url: nil, published_at: nil
    )
    assert_equal "magnet:?xt=test", result.download_link
  end

  test "Result.size_human returns formatted size" do
    result = ProwlarrClient::Result.new(
      guid: "test", title: "Test", indexer: "Test", size_bytes: 1073741824,
      seeders: 10, leechers: 5, download_url: nil, magnet_url: nil,
      info_url: nil, published_at: nil
    )
    assert_equal "1 GB", result.size_human
  end

  test "handles URLs with base path like /prowlarr" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696/prowlarr")
    ProwlarrClient.instance_variable_set(:@connection, nil)

    VCR.turned_off do
      # Should request /prowlarr/api/v1/health, not /api/v1/health
      stub_request(:get, "http://localhost:9696/prowlarr/api/v1/health")
        .to_return(status: 200, body: "[]")

      assert ProwlarrClient.test_connection
    end
  end

  test "handles URLs with trailing slash" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696/prowlarr/")
    ProwlarrClient.instance_variable_set(:@connection, nil)

    VCR.turned_off do
      stub_request(:get, "http://localhost:9696/prowlarr/api/v1/health")
        .to_return(status: 200, body: "[]")

      assert ProwlarrClient.test_connection
    end
  end

  test "configured_tags returns empty array when not set" do
    SettingsService.set(:prowlarr_tags, "")
    assert_equal [], ProwlarrClient.configured_tags
  end

  test "configured_tags parses comma-separated tag IDs" do
    SettingsService.set(:prowlarr_tags, "1, 5, 10")
    assert_equal [ 1, 5, 10 ], ProwlarrClient.configured_tags
  end

  test "configured_tags ignores invalid values" do
    SettingsService.set(:prowlarr_tags, "1, abc, 5")
    assert_equal [ 1, 5 ], ProwlarrClient.configured_tags
  end

  test "filtered_indexer_ids returns nil when no tags configured" do
    SettingsService.set(:prowlarr_tags, "")
    assert_nil ProwlarrClient.filtered_indexer_ids
  end

  test "filtered_indexer_ids filters indexers by tag" do
    SettingsService.set(:prowlarr_tags, "3")
    ProwlarrClient.instance_variable_set(:@connection, nil)

    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/indexer})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            { "id" => 1, "name" => "Indexer1", "tags" => [ 1, 2 ] },
            { "id" => 2, "name" => "Indexer2", "tags" => [ 3 ] },
            { "id" => 3, "name" => "Indexer3", "tags" => [ 2, 3 ] }
          ].to_json
        )

      result = ProwlarrClient.filtered_indexer_ids
      assert_equal [ 2, 3 ], result
    end
  end

  test "search passes indexerIds when tags configured" do
    SettingsService.set(:prowlarr_tags, "3")
    ProwlarrClient.instance_variable_set(:@connection, nil)

    VCR.turned_off do
      # Stub indexers endpoint
      stub_request(:get, %r{localhost:9696/api/v1/indexer})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            { "id" => 1, "name" => "Indexer1", "tags" => [ 1 ] },
            { "id" => 2, "name" => "Indexer2", "tags" => [ 3 ] }
          ].to_json
        )

      # Stub search endpoint - verify it includes indexerIds
      search_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with(query: hash_including("indexerIds" => "2"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      ProwlarrClient.search("test query")
      assert_requested search_stub
    end
  end
end
