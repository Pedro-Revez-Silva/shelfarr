# frozen_string_literal: true

require "test_helper"

class ProwlarrClientTest < ActiveSupport::TestCase
  # Indexer advertising the structured book search params Prowlarr needs before
  # it will accept a {title:}/{author:} query.
  STRUCTURED_INDEXER = {
    "id" => 1,
    "name" => "StructuredIndexer",
    "capabilities" => { "bookSearchParams" => [ "q", "author", "title" ] }
  }.freeze

  # The common case: a tracker that only accepts free text.
  FREE_TEXT_INDEXER = {
    "id" => 2,
    "name" => "FreeTextIndexer",
    "capabilities" => { "bookSearchParams" => [ "q" ] }
  }.freeze

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
              "publishDate" => "2024-01-15T10:00:00Z",
              "categories" => [ { "id" => 7020, "name" => "Books/EBook" } ]
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
      assert_equal [ 7020 ], result.category_ids
    end
  end

  test "search uses Prowlarr book search when title or author are provided" do
    VCR.turned_off do
      stub_indexers(STRUCTURED_INDEXER)

      search_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          query = req.uri.query_values
          query["type"] == "book" &&
            query["query"].include?("{title:Harry Potter and the Goblet of Fire}") &&
            query["query"].include?("{author:J.K. Rowling}") &&
            query["query"].include?("French")
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      results = ProwlarrClient.search(
        "French",
        book_type: :ebook,
        title: "Harry Potter and the Goblet of Fire",
        author: "J.K. Rowling"
      )

      assert_equal [], results
      assert_requested search_stub
    end
  end

  test "search sanitizes braces in structured book query values" do
    VCR.turned_off do
      stub_indexers(STRUCTURED_INDEXER)

      search_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          query = req.uri.query_values
          query["type"] == "book" &&
            query["query"].include?("{title:The Example Title}") &&
            query["query"].include?("{author:Ada Lovelace}") &&
            !query["query"].include?("{Title}") &&
            !query["query"].include?("{Ada}")
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      results = ProwlarrClient.search(
        "",
        book_type: :ebook,
        title: "The {Example} Title",
        author: "{Ada} Lovelace"
      )

      assert_equal [], results
      assert_requested search_stub
    end
  end

  test "search sends a free-text book query to indexers that only support q" do
    VCR.turned_off do
      stub_indexers(FREE_TEXT_INDEXER)

      search_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          query = req.uri.query_values

          query["type"] == "book" &&
            query["query"] == "Inferno Dan Brown" &&
            # A single plan covers every indexer Prowlarr would search anyway,
            # so it is left unrestricted rather than pinned to a selection.
            query["indexerIds"].nil?
        end
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      assert_equal [], ProwlarrClient.search("", book_type: :ebook, title: "Inferno", author: "Dan Brown")
      assert_requested search_stub
    end
  end

  test "search splits a book search by what each indexer can accept" do
    VCR.turned_off do
      stub_indexers(STRUCTURED_INDEXER, FREE_TEXT_INDEXER)

      structured_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          query = req.uri.query_values

          query["indexerIds"] == "1" &&
            query["query"] == "{title:Inferno} {author:Dan Brown}"
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "guid" => "structured-1", "title" => "Inferno", "indexer" => "StructuredIndexer" } ].to_json
        )

      free_text_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          query = req.uri.query_values

          query["indexerIds"] == "2" && query["query"] == "Inferno Dan Brown"
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "guid" => "free-text-1", "title" => "Inferno", "indexer" => "FreeTextIndexer" } ].to_json
        )

      results = ProwlarrClient.search("", book_type: :ebook, title: "Inferno", author: "Dan Brown")

      assert_equal [ "structured-1", "free-text-1" ], results.map(&:guid)
      assert_requested structured_stub
      assert_requested free_text_stub
    end
  end

  test "search falls back to a free-text book query when indexer capabilities are unavailable" do
    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/indexer}).to_return(status: 500, body: "")

      search_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          query = req.uri.query_values

          query["type"] == "book" &&
            query["query"] == "Inferno Dan Brown" &&
            query["indexerIds"].nil?
        end
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      assert_equal [], ProwlarrClient.search("", book_type: :ebook, title: "Inferno", author: "Dan Brown")
      assert_requested search_stub
    end
  end

  test "search does not plan around a disabled indexer" do
    VCR.turned_off do
      # /api/v1/indexer returns every configured definition, disabled ones
      # included, but Prowlarr will not search them: a selection naming only
      # disabled indexers fails the search outright.
      stub_indexers(STRUCTURED_INDEXER, FREE_TEXT_INDEXER.merge("enable" => false))

      structured_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          query = req.uri.query_values

          query["query"] == "{title:Inferno} {author:Dan Brown}" && query["indexerIds"].nil?
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "guid" => "structured-1", "title" => "Inferno", "indexer" => "StructuredIndexer" } ].to_json
        )

      results = ProwlarrClient.search("", book_type: :ebook, title: "Inferno", author: "Dan Brown")

      assert_equal [ "structured-1" ], results.map(&:guid)
      assert_requested structured_stub
      assert_not_requested :get, %r{localhost:9696/api/v1/search}, query: hash_including("indexerIds" => "2")
    end
  end

  test "search does not plan around an indexer Prowlarr has temporarily blocked" do
    VCR.turned_off do
      blocked = FREE_TEXT_INDEXER.merge("status" => { "disabledTill" => 1.hour.from_now.utc.iso8601 })
      stub_indexers(STRUCTURED_INDEXER, blocked)

      structured_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["query"] == "{title:Inferno} {author:Dan Brown}" }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      assert_equal [], ProwlarrClient.search("", book_type: :ebook, title: "Inferno", author: "Dan Brown")
      assert_requested structured_stub
      assert_not_requested :get, %r{localhost:9696/api/v1/search}, query: hash_including("query" => "Inferno Dan Brown")
    end
  end

  test "search returns nothing when every indexer in scope is unavailable" do
    VCR.turned_off do
      stub_indexers(
        STRUCTURED_INDEXER.merge("enable" => false),
        FREE_TEXT_INDEXER.merge("enable" => false)
      )

      assert_equal [], ProwlarrClient.search("", book_type: :ebook, title: "Inferno", author: "Dan Brown")
      assert_not_requested :get, %r{localhost:9696/api/v1/search}
    end
  end

  test "search keeps the results of a plan that succeeded when another plan fails" do
    VCR.turned_off do
      # An indexer can be disabled or blocked between reading the list and
      # running the search; Prowlarr then answers 400 for that selection.
      stub_indexers(STRUCTURED_INDEXER, FREE_TEXT_INDEXER)

      structured_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["indexerIds"] == "1" }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "guid" => "structured-1", "title" => "Inferno", "indexer" => "StructuredIndexer" } ].to_json
        )

      free_text_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["indexerIds"] == "2" }
        .to_return(status: 400, body: "")

      results = ProwlarrClient.search("", book_type: :ebook, title: "Inferno", author: "Dan Brown")

      assert_equal [ "structured-1" ], results.map(&:guid)
      assert_requested structured_stub
      assert_requested free_text_stub
    end
  end

  test "search raises when every book search plan fails" do
    VCR.turned_off do
      stub_indexers(STRUCTURED_INDEXER, FREE_TEXT_INDEXER)
      stub_request(:get, %r{localhost:9696/api/v1/search}).to_return(status: 400, body: "")

      assert_raises IndexerClients::Base::Error do
        ProwlarrClient.search("", book_type: :ebook, title: "Inferno", author: "Dan Brown")
      end
    end
  end

  test "search de-duplicates plan results by guid, keeping the higher-priority indexer" do
    VCR.turned_off do
      # Prowlarr de-duplicates by GUID within one search and keeps the copy from
      # the indexer with the lowest priority number. Splitting the search across
      # plans makes that this client's job.
      stub_indexers(
        STRUCTURED_INDEXER.merge("priority" => 50),
        FREE_TEXT_INDEXER.merge("priority" => 1)
      )

      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["indexerIds"] == "1" }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ { "guid" => "shared", "title" => "Inferno", "indexer" => "StructuredIndexer", "indexerId" => 1 } ].to_json
        )

      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["indexerIds"] == "2" }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            { "guid" => "shared", "title" => "Inferno", "indexer" => "FreeTextIndexer", "indexerId" => 2 },
            { "guid" => "free-text-only", "title" => "Inferno", "indexer" => "FreeTextIndexer", "indexerId" => 2 }
          ].to_json
        )

      results = ProwlarrClient.search("", book_type: :ebook, title: "Inferno", author: "Dan Brown")

      assert_equal [ "shared", "free-text-only" ], results.map(&:guid)
      assert_equal "FreeTextIndexer", results.first.indexer
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

  test "extract_download_url redacts sensitive query params in logs" do
    logger = Struct.new(:messages) do
      def debug(message)
        messages << message
      end
    end.new([])

    item = {
      "indexer" => "TestIndexer",
      "downloadUrl" => "http://prowlarr:9696/11/download?apikey=secret&file=Atomic+Habits"
    }

    url = Rails.stub(:logger, logger) do
      ProwlarrClient.send(:extract_download_url, item)
    end

    assert_equal item["downloadUrl"], url
    assert_includes logger.messages.first, "apikey=[REDACTED]"
    assert_includes logger.messages.first, "file=Atomic+Habits"
    assert_not_includes logger.messages.first, "apikey=secret"
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
      # Should request /prowlarr/api/v1/indexer, not /api/v1/indexer
      stub_request(:get, "http://localhost:9696/prowlarr/api/v1/indexer")
        .to_return(status: 200, body: "[]")

      assert ProwlarrClient.test_connection
    end
  end

  test "handles URLs with trailing slash" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696/prowlarr/")
    ProwlarrClient.instance_variable_set(:@connection, nil)

    VCR.turned_off do
      stub_request(:get, "http://localhost:9696/prowlarr/api/v1/indexer")
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

  test "configured_tag_names parses non-numeric tag values" do
    SettingsService.set(:prowlarr_tags, "1, books, 5,  bookshelf ")
    assert_equal [ "books", "bookshelf" ], ProwlarrClient.send(:configured_tag_names)
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

  test "filtered_indexer_ids resolves tag names to IDs" do
    SettingsService.set(:prowlarr_tags, "books")
    ProwlarrClient.instance_variable_set(:@connection, nil)

    VCR.turned_off do
      # Stub tags endpoint to map tag name to ID
      stub_request(:get, %r{localhost:9696/api/v1/tag})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            { "id" => 7, "label" => "other" },
            { "id" => 42, "label" => "books" }
          ].to_json
        )

      # Stub indexers endpoint
      stub_request(:get, %r{localhost:9696/api/v1/indexer})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            { "id" => 1, "name" => "Indexer1", "tags" => [ 7 ] },
            { "id" => 2, "name" => "Indexer2", "tags" => [ 42 ] }
          ].to_json
        )

      assert_equal [ 2 ], ProwlarrClient.filtered_indexer_ids
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

  test "search passes indexerIds when tags configured by name" do
    SettingsService.set(:prowlarr_tags, "books")
    ProwlarrClient.instance_variable_set(:@connection, nil)

    VCR.turned_off do
      # Stub tags endpoint to map tag name to ID
      stub_request(:get, %r{localhost:9696/api/v1/tag})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            { "id" => 7, "label" => "other" },
            { "id" => 42, "label" => "books" }
          ].to_json
        )

      # Stub indexers endpoint
      stub_request(:get, %r{localhost:9696/api/v1/indexer})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            { "id" => 1, "name" => "Indexer1", "tags" => [ 7 ] },
            { "id" => 2, "name" => "Indexer2", "tags" => [ 42 ] }
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

  test "book search keeps a name-resolved tag scope when the tag endpoint fails again" do
    SettingsService.set(:prowlarr_tags, "books")
    ProwlarrClient.instance_variable_set(:@connection, nil)

    VCR.turned_off do
      # The tag names resolve once, then the endpoint starts failing. The scope
      # was already resolved, so the book search must still be restricted to it.
      stub_request(:get, %r{localhost:9696/api/v1/tag})
        .to_return(
          {
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: [ { "id" => 42, "label" => "books" } ].to_json
          },
          {
            status: 500,
            headers: { "Content-Type" => "application/json" },
            body: { "error" => "boom" }.to_json
          }
        )

      # Both are free-text only, so the split leaves a single plan — the path
      # that drops indexerIds when nothing is scoping the search.
      stub_indexers(
        { "id" => 1, "name" => "Untagged", "tags" => [ 7 ],
          "capabilities" => { "bookSearchParams" => [ "q" ] } },
        { "id" => 2, "name" => "Tagged", "tags" => [ 42 ],
          "capabilities" => { "bookSearchParams" => [ "q" ] } }
      )

      search_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with(query: hash_including("type" => "book", "indexerIds" => "2"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      ProwlarrClient.search("", title: "Frankenstein", author: "Mary Shelley")
      assert_requested search_stub
    end
  end

  # SSL error handling tests
  test "test_connection returns false on SSL error" do
    VCR.turned_off do
      request = stub_request(:get, "http://localhost:9696/api/v1/indexer")
        .to_raise(Faraday::SSLError.new("SSL certificate verify failed"))

      assert_not ProwlarrClient.test_connection
      assert_requested request, times: 1
    end
  end

  test "search raises ConnectionError on SSL error" do
    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .to_raise(Faraday::SSLError.new("SSL certificate verify failed"))

      assert_raises ProwlarrClient::ConnectionError do
        ProwlarrClient.search("test query")
      end
    end
  end

  test "test_connection retries one transient connection failure" do
    VCR.turned_off do
      request = stub_request(:get, "http://localhost:9696/api/v1/indexer")
        .to_raise(Faraday::ConnectionFailed.new("Connection refused"))
        .then
        .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })

      assert ProwlarrClient.test_connection
      assert_requested request, times: 2
    end
  end

  test "search retries one transient timeout" do
    VCR.turned_off do
      request = stub_request(:get, %r{localhost:9696/api/v1/search})
        .to_raise(Faraday::TimeoutError.new("execution expired"))
        .then
        .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })

      assert_equal [], ProwlarrClient.search("test")
      assert_requested request, times: 2
    end
  end

  test "search stops after one retry when connection failures persist" do
    VCR.turned_off do
      request = stub_request(:get, %r{localhost:9696/api/v1/search})
        .to_raise(Faraday::ConnectionFailed.new("Connection reset by peer"))

      assert_raises ProwlarrClient::ConnectionError do
        ProwlarrClient.search("test")
      end
      assert_requested request, times: 2
    end
  end

  test "search does not retry API responses" do
    VCR.turned_off do
      request = stub_request(:get, %r{localhost:9696/api/v1/search})
        .to_return(status: 503, body: { error: "unavailable" }.to_json,
          headers: { "Content-Type" => "application/json" })

      assert_raises ProwlarrClient::Error do
        ProwlarrClient.search("test")
      end
      assert_requested request, times: 1
    end
  end

  private

  def stub_indexers(*indexers)
    stub_request(:get, %r{localhost:9696/api/v1/indexer})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: indexers.to_json
      )
  end
end
