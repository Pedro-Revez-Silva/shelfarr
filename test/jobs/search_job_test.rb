# frozen_string_literal: true

require "test_helper"

class SearchJobTest < ActiveJob::TestCase
  setup do
    @request = requests(:pending_request)
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-key")
    SettingsService.set(:zlibrary_enabled, false)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "")
    SettingsService.set(:zlibrary_password, "")
    ZLibraryClient.reset_connection! if defined?(ZLibraryClient)
  end

  teardown do
    SettingsService.set(:zlibrary_enabled, false)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "")
    SettingsService.set(:zlibrary_password, "")
    ZLibraryClient.reset_connection! if defined?(ZLibraryClient)
  end

  test "updates request status to searching" do
    VCR.turned_off do
      stub_prowlarr_search_with_results

      SearchJob.perform_now(@request.id)
      @request.reload

      assert @request.searching?
    end
  end

  test "creates search results from Prowlarr response" do
    VCR.turned_off do
      stub_prowlarr_search_with_results

      SearchJob.perform_now(@request.id)
      @request.reload

      assert @request.searching?
      assert @request.search_results.any?
      assert_equal "Test Result Book", @request.search_results.first.title
    end
  end

  test "schedules retry when no results found" do
    VCR.turned_off do
      stub_prowlarr_search_empty

      SearchJob.perform_now(@request.id)
      @request.reload

      assert @request.not_found?
      assert @request.next_retry_at.present?
    end
  end

  test "marks for attention when no search sources configured" do
    SettingsService.set(:prowlarr_api_key, "")
    SettingsService.set(:anna_archive_enabled, false)

    SearchJob.perform_now(@request.id)
    @request.reload

    assert @request.attention_needed?
    assert_includes @request.issue_description, "No search sources configured"
  end

  test "sends attention notification when no search sources configured" do
    SettingsService.set(:prowlarr_api_key, "")
    SettingsService.set(:anna_archive_enabled, false)
    attention_requests = []

    NotificationService.stub :request_attention, ->(req) { attention_requests << req } do
      SearchJob.perform_now(@request.id)
    end

    assert_equal [ @request ], attention_requests
  end

  test "skips non-pending requests" do
    @request.update!(status: :searching)

    SearchJob.perform_now(@request.id)
    @request.reload

    # Status should not change
    assert @request.searching?
  end

  test "skips non-existent requests" do
    # Should not raise error
    assert_nothing_raised do
      SearchJob.perform_now(999999)
    end
  end

  test "includes audiobook in search query for audiobook requests" do
    audiobook_book = books(:audiobook_acquired)
    request = Request.create!(book: audiobook_book, user: users(:one), status: :pending)

    VCR.turned_off do
      # Stub that verifies "audiobook" is in the query
      stub_request(:get, %r{localhost:9696/api/v1/search.*audiobook}i)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      assert_nothing_raised do
        SearchJob.perform_now(request.id)
      end
    end
  end

  test "marks for attention when auto-select is disabled and results found" do
    SettingsService.set(:auto_select_enabled, false)

    VCR.turned_off do
      stub_prowlarr_search_with_results

      SearchJob.perform_now(@request.id)
      @request.reload

      assert @request.searching?
      assert @request.attention_needed?
      assert_includes @request.issue_description, "Please review and select a result"
    end
  end

  test "sends attention notification when auto-select is disabled" do
    SettingsService.set(:auto_select_enabled, false)

    VCR.turned_off do
      stub_prowlarr_search_with_results
      attention_requests = []

      NotificationService.stub :request_attention, ->(req) { attention_requests << req } do
        SearchJob.perform_now(@request.id)
      end

      assert_equal [ @request ], attention_requests
    end
  end

  test "marks for attention when auto-select fails to find suitable result" do
    SettingsService.set(:auto_select_enabled, true)

    VCR.turned_off do
      stub_prowlarr_search_with_results

      # Mock AutoSelectService to return failure
      AutoSelectService.stub :call, OpenStruct.new(success?: false) do
        SearchJob.perform_now(@request.id)
      end
      @request.reload

      assert @request.searching?
      assert @request.attention_needed?
      assert_includes @request.issue_description, "none matched auto-select criteria"
    end
  end

  test "sends attention notification when auto-select fails" do
    SettingsService.set(:auto_select_enabled, true)

    VCR.turned_off do
      stub_prowlarr_search_with_results
      attention_requests = []

      NotificationService.stub :request_attention, ->(req) { attention_requests << req } do
        AutoSelectService.stub :call, OpenStruct.new(success?: false) do
          SearchJob.perform_now(@request.id)
        end
      end

      assert_equal [ @request ], attention_requests
    end
  end

  test "sends attention notification on indexer authentication failure" do
    VCR.turned_off do
      stub_request(:get, %r{localhost:9696}).to_raise(IndexerClients::Base::AuthenticationError.new("Invalid API key"))
      attention_requests = []

      NotificationService.stub :request_attention, ->(req) { attention_requests << req } do
        SearchJob.perform_now(@request.id)
      end

      assert_equal [ @request ], attention_requests
    end
  end

  test "sends attention notification on Anna's Archive bot protection" do
    SettingsService.set(:prowlarr_api_key, "")
    attention_requests = []

    AnnaArchiveClient.stub :configured?, true do
      AnnaArchiveClient.stub :search, ->(*, **) {
        raise AnnaArchiveClient::BotProtectionError, "Configure FlareSolverr"
      } do
        NotificationService.stub :request_attention, ->(req) { attention_requests << req } do
          SearchJob.perform_now(@request.id)
        end
      end
    end

    assert_equal [ @request ], attention_requests
  end

  test "does not mark for attention when auto-select succeeds" do
    SettingsService.set(:auto_select_enabled, true)

    VCR.turned_off do
      stub_prowlarr_search_with_results

      # Mock AutoSelectService to return success
      AutoSelectService.stub :call, OpenStruct.new(success?: true) do
        SearchJob.perform_now(@request.id)
      end
      @request.reload

      assert @request.searching?
      assert_not @request.attention_needed?
    end
  end

  test "includes language in search query for non-English requests" do
    # Set request language to French
    @request.update!(language: "fr")

    VCR.turned_off do
      # Prowlarr book search should keep language as free text while title/author are structured
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          query = req.uri.query_values["query"]
          req.uri.query_values["type"] == "book" &&
            query.include?("French") &&
            query.include?("{title:#{@request.book.title}}") &&
            query.include?("{author:#{@request.book.author}}")
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ prowlarr_result_payload ].to_json
        )

      assert_nothing_raised do
        SearchJob.perform_now(@request.id)
      end
    end
  end

  test "does not add language to search query for English requests" do
    # Set request language to English
    @request.update!(language: "en")

    VCR.turned_off do
      # Prowlarr book search should omit the English language hint
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          query = req.uri.query_values["query"]
          req.uri.query_values["type"] == "book" &&
            !query.include?("English") &&
            query.include?("{title:#{@request.book.title}}") &&
            query.include?("{author:#{@request.book.author}}")
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ prowlarr_result_payload ].to_json
        )

      assert_nothing_raised do
        SearchJob.perform_now(@request.id)
      end
    end
  end

  test "uses structured Prowlarr book search with title and author" do
    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          query = req.uri.query_values["query"]
          req.uri.query_values["type"] == "book" &&
            query.include?("{title:#{@request.book.title}}") &&
            query.include?("{author:#{@request.book.author}}")
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ prowlarr_result_payload ].to_json
        )

      assert_nothing_raised do
        SearchJob.perform_now(@request.id)
      end
    end
  end

  test "falls back to generic Prowlarr search when book search returns no results" do
    VCR.turned_off do
      structured_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          query = req.uri.query_values["query"]
          req.uri.query_values["type"] == "book" &&
            query.include?("{title:#{@request.book.title}}") &&
            query.include?("{author:#{@request.book.author}}")
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      fallback_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == @request.book.title
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ prowlarr_result_payload ].to_json
        )

      SearchJob.perform_now(@request.id)
      @request.reload

      assert_requested structured_stub
      assert_requested fallback_stub
      assert_equal "Test Result Book", @request.search_results.first.title
    end
  end

  test "retries with apostrophe-normalized generic query when fallback query has no results" do
    book = Book.create!(
      title: "Carl’s Doomsday Scenario",
      author: "Matt Dinniman",
      book_type: :audiobook
    )
    request = Request.create!(book: book, user: users(:one), status: :pending)

    VCR.turned_off do
      structured_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "book" &&
            req.uri.query_values["query"].include?("{title:Carl’s Doomsday Scenario}") &&
            req.uri.query_values["query"].include?("{author:Matt Dinniman}")
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      generic_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "Carl’s Doomsday Scenario"
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      normalized_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "Carls Doomsday Scenario"
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ prowlarr_result_payload ].to_json
        )

      SearchJob.perform_now(request.id)
      request.reload

      assert_requested structured_stub
      assert_requested generic_stub
      assert_requested normalized_stub
      assert_equal "Test Result Book", request.search_results.first.title
    end
  end

  test "sanitizes braces in structured Prowlarr query values" do
    book = Book.create!(
      title: "The {Brace} Book",
      author: "Author {Name}",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: users(:one), status: :pending)

    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          query = req.uri.query_values["query"]
          req.uri.query_values["type"] == "book" &&
            query.include?("{title:The Brace Book}") &&
            query.include?("{author:Author Name}") &&
            !query.include?("{Brace}") &&
            !query.include?("{Name}")
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ prowlarr_result_payload ].to_json
        )

      SearchJob.perform_now(request.id)
      request.reload

      assert request.search_results.any?
    end
  end

  test "keeps Jackett on title-only generic search" do
    SettingsService.set(:indexer_provider, "jackett")
    SettingsService.set(:jackett_url, "http://localhost:9117")
    SettingsService.set(:jackett_api_key, "jackett-key")

    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
        <channel></channel>
      </rss>
    XML

    VCR.turned_off do
      stub_request(:get, %r{localhost:9117/api/v2\.0/indexers/all/results/torznab/api})
        .with do |req|
          query = req.uri.query_values["q"]
          req.uri.query_values["t"] == "search" &&
            query.include?(@request.book.title) &&
            !query.include?(@request.book.author)
        end
        .to_return(status: 200, body: body, headers: { "Content-Type" => "application/xml" })

      assert_nothing_raised do
        SearchJob.perform_now(@request.id)
      end
    end
  end

  test "still appends author to Anna's Archive search query" do
    SettingsService.set(:prowlarr_api_key, "")
    result = AnnaArchiveClient::Result.new(
      md5: "abc123def456",
      title: @request.book.title,
      author: @request.book.author,
      year: 2019,
      file_type: "epub",
      file_size: "5 MB",
      language: "en"
    )

    AnnaArchiveClient.stub :configured?, true do
      AnnaArchiveClient.stub :search, ->(query, **_) {
        assert_includes query, @request.book.title
        assert_includes query, @request.book.author
        [ result ]
      } do
        SearchJob.perform_now(@request.id)
        @request.reload

        assert_equal SearchResult::SOURCE_ANNA_ARCHIVE, @request.search_results.first.source
      end
    end
  end

  test "handles unknown language code gracefully" do
    # Set request language to unknown code
    @request.update!(language: "xyz")

    VCR.turned_off do
      # Stub search - unknown language should not be added to query
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| !req.uri.query_values["query"].include?("xyz") }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      assert_nothing_raised do
        SearchJob.perform_now(@request.id)
      end
    end
  end

  test "includes z-library results when enabled and anna is unavailable" do
    SettingsService.set(:prowlarr_api_key, "")
    SettingsService.set(:zlibrary_enabled, true)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "reader@example.com")
    SettingsService.set(:zlibrary_password, "secret")

    result = ZLibraryClient::Result.new(
      id: "999",
      hash: "deadbeef",
      title: "Z-Library Result",
      author: @request.book.author,
      year: 2024,
      file_type: "epub",
      file_size: 5_452_595,
      language: "en"
    )

    ZLibraryClient.stub :search, ->(query, language: nil, **) {
      assert_includes query, @request.book.title
      assert_equal "english", language
      [result]
    } do
      SearchJob.perform_now(@request.id)
    end

    @request.reload
    saved_result = @request.search_results.first
    assert_equal SearchResult::SOURCE_ZLIBRARY, saved_result.source
    assert_equal "999:deadbeef", saved_result.guid
    assert_equal "Z-Library", saved_result.indexer
  end

  test "continues to z-library when indexer URL is invalid" do
    SettingsService.set(:prowlarr_url, "localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-key")
    SettingsService.set(:anna_archive_enabled, false)
    SettingsService.set(:zlibrary_enabled, true)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "reader@example.com")
    SettingsService.set(:zlibrary_password, "secret")

    result = ZLibraryClient::Result.new(
      id: "999",
      hash: "deadbeef",
      title: "Z-Library Result",
      author: @request.book.author,
      year: 2024,
      file_type: "epub",
      file_size: 5_452_595,
      language: "en"
    )

    ZLibraryClient.stub :search, [result] do
      assert_nothing_raised do
        SearchJob.perform_now(@request.id)
      end
    end

    @request.reload
    assert_equal SearchResult::SOURCE_ZLIBRARY, @request.search_results.first.source
    assert @request.attention_needed?
  end

  test "skips z-library when anna archive is configured" do
    SettingsService.set(:prowlarr_api_key, "")
    SettingsService.set(:anna_archive_enabled, true)
    SettingsService.set(:anna_archive_api_key, "aa-key")
    SettingsService.set(:zlibrary_enabled, true)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "reader@example.com")
    SettingsService.set(:zlibrary_password, "secret")

    AnnaArchiveClient.stub :search, [] do
      ZLibraryClient.stub :search, ->(*) { flunk "Z-Library should not be searched when Anna's Archive is available" } do
        SearchJob.perform_now(@request.id)
      end
    end

    @request.reload
    assert @request.not_found?
    assert @request.search_results.none? { |result| result.source == SearchResult::SOURCE_ZLIBRARY }
  end

  test "marks z-library as a valid configured source" do
    SettingsService.set(:prowlarr_api_key, "")
    SettingsService.set(:zlibrary_enabled, true)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "reader@example.com")
    SettingsService.set(:zlibrary_password, "secret")

    ZLibraryClient.stub :search, [] do
      SearchJob.perform_now(@request.id)
    end

    @request.reload
    assert @request.not_found?
    assert_not @request.attention_needed?
  end

  test "uses jackett when explicitly selected as the indexer provider" do
    SettingsService.set(:indexer_provider, "jackett")
    SettingsService.set(:jackett_url, "http://localhost:9117")
    SettingsService.set(:jackett_api_key, "jackett-key")

    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
        <channel>
          <item>
            <title>Jackett Search Result</title>
            <guid>jackett-guid-1</guid>
            <link>https://example.com/details/1</link>
            <jackettindexer>JackettBooks</jackettindexer>
            <enclosure url="magnet:?xt=urn:btih:jackett1" length="12345" type="application/x-bittorrent" />
            <torznab:attr name="seeders" value="12" />
          </item>
        </channel>
      </rss>
    XML

    VCR.turned_off do
      stub_request(:get, %r{localhost:9117/api/v2\.0/indexers/all/results/torznab/api})
        .with(query: hash_including("apikey" => "jackett-key", "t" => "search"))
        .to_return(status: 200, body: body, headers: { "Content-Type" => "application/xml" })

      SearchJob.perform_now(@request.id)
      @request.reload

      assert @request.search_results.any?
      assert_equal SearchResult::SOURCE_JACKETT, @request.search_results.first.source
      assert_equal "JackettBooks", @request.search_results.first.indexer
    end
  end

  private

  def stub_prowlarr_search_with_results
    stub_request(:get, %r{localhost:9696/api/v1/search})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: [ prowlarr_result_payload ].to_json
      )
  end

  def stub_prowlarr_search_empty
    stub_request(:get, %r{localhost:9696/api/v1/search})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: [].to_json
      )
  end

  def prowlarr_result_payload
    {
      "guid" => "test-guid-123",
      "title" => "Test Result Book",
      "indexer" => "TestIndexer",
      "size" => 52_428_800,
      "seeders" => 25,
      "leechers" => 5,
      "downloadUrl" => "http://example.com/download",
      "magnetUrl" => "magnet:?xt=urn:btih:test123",
      "infoUrl" => "http://example.com/info",
      "publishDate" => "2024-01-15T10:00:00Z"
    }
  end
end
