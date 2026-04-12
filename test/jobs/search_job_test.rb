# frozen_string_literal: true

require "test_helper"

class SearchJobTest < ActiveJob::TestCase
  setup do
    @request = requests(:pending_request)
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-key")
    ZLibraryClient.reset_auth_cache! if defined?(ZLibraryClient)
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

  test "includes Z-Library results when configured" do
    SettingsService.set(:prowlarr_api_key, "")
    SettingsService.set(:zlibrary_email, "test@example.com")
    SettingsService.set(:zlibrary_password, "testpass")

    result = ZLibraryClient::Result.new(
      id: "999",
      hash: "deadbeef",
      title: "Z-Library Book",
      author: "Test Author",
      year: 2023,
      file_type: "epub",
      file_size: 5452595,
      language: "english"
    )

    ZLibraryClient.stub :configured?, true do
      ZLibraryClient.stub :search, ->(query, **_) {
        assert_includes query, @request.book.title
        [result]
      } do
        SearchJob.perform_now(@request.id)
        @request.reload

        assert @request.search_results.any?
        assert_equal SearchResult::SOURCE_ZLIBRARY, @request.search_results.first.source
        assert_equal "Z-Library", @request.search_results.first.indexer
        assert_equal "999:deadbeef", @request.search_results.first.guid
      end
    end

    SettingsService.set(:zlibrary_email, "")
    SettingsService.set(:zlibrary_password, "")
  end

  test "does not search Z-Library when not configured" do
    SettingsService.set(:zlibrary_email, "")

    VCR.turned_off do
      stub_prowlarr_search_with_results

      SearchJob.perform_now(@request.id)
      @request.reload

      assert @request.search_results.any?
      assert @request.search_results.none? { |r| r.source == SearchResult::SOURCE_ZLIBRARY }
    end
  end

  test "does not search Z-Library for audiobook requests" do
    SettingsService.set(:zlibrary_email, "test@example.com")
    SettingsService.set(:zlibrary_password, "testpass")

    audiobook_book = books(:audiobook_acquired)
    request = Request.create!(book: audiobook_book, user: users(:one), status: :pending)

    VCR.turned_off do
      stub_prowlarr_search_with_results

      ZLibraryClient.stub :configured?, true do
        ZLibraryClient.stub :search, ->(*) { raise "Should not be called" } do
          assert_nothing_raised do
            SearchJob.perform_now(request.id)
          end
        end
      end
    end

    SettingsService.set(:zlibrary_email, "")
    SettingsService.set(:zlibrary_password, "")
  end

  test "Z-Library errors do not block other search sources" do
    SettingsService.set(:zlibrary_email, "test@example.com")
    SettingsService.set(:zlibrary_password, "testpass")

    VCR.turned_off do
      stub_prowlarr_search_with_results

      ZLibraryClient.stub :configured?, true do
        ZLibraryClient.stub :search, ->(*) { raise ZLibraryClient::ConnectionError, "Z-Library down" } do
          SearchJob.perform_now(@request.id)
          @request.reload

          # Prowlarr results should still be saved despite Z-Library failure
          assert @request.search_results.any?
          assert @request.search_results.none? { |r| r.source == SearchResult::SOURCE_ZLIBRARY }
        end
      end
    end

    SettingsService.set(:zlibrary_email, "")
    SettingsService.set(:zlibrary_password, "")
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
