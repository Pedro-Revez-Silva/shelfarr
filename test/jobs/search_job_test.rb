# frozen_string_literal: true

require "test_helper"

class SearchJobTest < ActiveJob::TestCase
  setup do
    @request = requests(:pending_request)
    @request.search_results.blocklisted.destroy_all
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-key")
    SettingsService.set(:zlibrary_enabled, false)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "")
    SettingsService.set(:zlibrary_password, "")
    SettingsService.set(:librivox_enabled, false)
    SettingsService.set(:librivox_url, "https://librivox.org")
    SettingsService.set(:gutenberg_enabled, false)
    SettingsService.set(:gutenberg_url, "https://www.gutenberg.org")
    SettingsService.set(:indexer_search_scope, "broad")
    SettingsService.set(:indexer_custom_audiobook_categories, "")
    SettingsService.set(:indexer_custom_ebook_categories, "")
    ZLibraryClient.reset_connection! if defined?(ZLibraryClient)
    LibrivoxClient.reset_connection! if defined?(LibrivoxClient)
    GutenbergClient.reset_connection! if defined?(GutenbergClient)
  end

  teardown do
    SettingsService.set(:zlibrary_enabled, false)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "")
    SettingsService.set(:zlibrary_password, "")
    SettingsService.set(:librivox_enabled, false)
    SettingsService.set(:librivox_url, "https://librivox.org")
    SettingsService.set(:gutenberg_enabled, false)
    SettingsService.set(:gutenberg_url, "https://www.gutenberg.org")
    SettingsService.set(:indexer_search_scope, "broad")
    SettingsService.set(:indexer_custom_audiobook_categories, "")
    SettingsService.set(:indexer_custom_ebook_categories, "")
    ZLibraryClient.reset_connection! if defined?(ZLibraryClient)
    LibrivoxClient.reset_connection! if defined?(LibrivoxClient)
    GutenbergClient.reset_connection! if defined?(GutenbergClient)
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

  test "preserves manual download results when saving new results" do
    VCR.turned_off do
      stub_prowlarr_search_with_results

      manual_result = @request.search_results.create!(
        guid: "manual-magnet:#{'b' * 40}",
        title: "Manual magnet result",
        magnet_url: "magnet:?xt=urn:btih:#{'b' * 40}",
        source: SearchResult::SOURCE_MANUAL_MAGNET,
        indexer: "Manual Magnet",
        status: :selected
      )
      manual_nzb = @request.search_results.create!(
        guid: "manual-nzb:#{'c' * 64}",
        title: "Manual NZB result",
        download_url: "https://downloads.example/book.nzb",
        seeders: nil,
        source: SearchResult::SOURCE_MANUAL_NZB,
        indexer: "Manual NZB",
        status: :selected
      )

      SearchJob.perform_now(@request.id)
      @request.reload

      assert_includes @request.search_results, manual_result
      assert manual_result.reload.selected?
      assert_includes @request.search_results, manual_nzb
      assert manual_nzb.reload.selected?
    end
  end

  test "save_results preserves blocklist for guid absent from refreshed search" do
    blocklisted = @request.search_results.create!(
      guid: "persist-blocklist-guid",
      title: "Failed Release",
      indexer: "FailedIndexer",
      magnet_url: "magnet:?xt=urn:btih:persist",
      status: :rejected,
      blocklisted_at: 2.days.ago,
      blocklist_reason: "Bad release"
    )

    SearchJob.new.send(:save_results, @request, [])

    carried = @request.search_results.find_by!(guid: blocklisted.guid)
    assert carried.blocklisted?
    assert_equal "Bad release", carried.blocklist_reason
    assert carried.rejected?
  end

  test "save_results preserves selected result absent from refreshed search" do
    selected = @request.search_results.create!(
      guid: "persist-selected-guid",
      title: "Downloading Release",
      indexer: "TestIndexer",
      magnet_url: "magnet:?xt=urn:btih:selected",
      status: :selected
    )
    download = @request.downloads.create!(name: selected.title, search_result: selected, status: :downloading)

    SearchJob.new.send(:save_results, @request, [])

    assert selected.reload.selected?
    assert_equal selected.id, download.reload.search_result_id
  end

  test "save_results carries blocklist forward by guid" do
    blocklisted = @request.search_results.create!(
      guid: "carry-blocklist-guid",
      title: "Failed Release",
      indexer: "FailedIndexer",
      magnet_url: "magnet:?xt=urn:btih:carry",
      status: :rejected,
      blocklisted_at: 2.days.ago,
      blocklist_reason: "Bad release"
    )
    tagged_result = {
      source: SearchResult::SOURCE_PROWLARR,
      result: OpenStruct.new(
        guid: "carry-blocklist-guid",
        title: "The Pending Ebook Another Author EPUB",
        indexer: "TestIndexer",
        size_bytes: 123_456,
        seeders: 10,
        leechers: 1,
        download_url: nil,
        magnet_url: "magnet:?xt=urn:btih:carried",
        info_url: nil,
        published_at: nil
      )
    }

    SearchJob.new.send(:save_results, @request, [ tagged_result ])

    carried = @request.search_results.find_by!(guid: "carry-blocklist-guid")
    assert carried.blocklisted?
    assert_equal "Bad release", carried.blocklist_reason
    assert carried.rejected?
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
      stub_prowlarr_generic_search_empty

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
      stub_prowlarr_generic_search_empty

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
      stub_prowlarr_generic_search_empty

      assert_nothing_raised do
        SearchJob.perform_now(@request.id)
      end
    end
  end

  test "falls back to generic Prowlarr search when book search returns no results" do
    generic_payload = prowlarr_result_payload.merge(
      "guid" => "generic-strong-match",
      "title" => "#{@request.book.title} #{@request.book.author} EPUB"
    )

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
            req.uri.query_values["query"] == @request.book.title &&
            category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ generic_payload ].to_json
        )

      broad_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == @request.book.title &&
            !category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      SearchJob.perform_now(@request.id)
      @request.reload

      assert_requested structured_stub
      assert_requested fallback_stub
      assert_requested broad_stub
      assert_equal generic_payload["title"], @request.search_results.first.title
    end
  end

  test "tries numeric title variants when Prowlarr exact title searches are empty" do
    SettingsService.set(:indexer_search_scope, "strict")
    book = Book.create!(
      title: "The Perfect Run III",
      author: "Maxime Durand",
      book_type: :audiobook
    )
    request = Request.create!(book: book, user: users(:one), status: :pending)
    numeric_payload = prowlarr_result_payload.merge(
      "guid" => "perfect-run-3",
      "title" => "The Perfect Run 3 Maxime Durand Audiobook M4B",
      "categories" => [ { "id" => 3030, "name" => "Audio/Audiobook" } ]
    )

    VCR.turned_off do
      structured_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "book" }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      exact_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "The Perfect Run III" &&
            category_query_param?(req)
        end
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      title_author_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "The Perfect Run III Maxime Durand" &&
            category_query_param?(req)
        end
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      author_title_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "Maxime Durand The Perfect Run III" &&
            category_query_param?(req)
        end
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      numeric_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "The Perfect Run 3" &&
            category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ numeric_payload ].to_json
        )

      # The numeric result lands below the confidence threshold once its
      # attempt penalty is applied, so the search keeps broadening.
      numeric_author_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "The Perfect Run 3 Maxime Durand" &&
            category_query_param?(req)
        end
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      SearchJob.perform_now(request.id)
      request.reload

      assert_requested structured_stub
      assert_requested exact_stub
      assert_requested title_author_stub
      assert_requested author_title_stub
      assert_requested numeric_stub
      assert_requested numeric_author_stub
      assert_equal numeric_payload["title"], request.search_results.first.title
      assert_equal "number_variant", request.search_results.first.score_breakdown["search_attempt"]
      assert_equal 12, request.search_results.first.score_breakdown["search_penalty"]
    end
  end

  test "tries author title Prowlarr query when title first queries are empty" do
    SettingsService.set(:indexer_search_scope, "strict")
    book = Book.create!(
      title: "Awkward Indexer Title",
      author: "Specific Author",
      book_type: :audiobook
    )
    request = Request.create!(book: book, user: users(:one), status: :pending)
    author_title_payload = prowlarr_result_payload.merge(
      "guid" => "author-title-match",
      "title" => "Specific Author Awkward Indexer Title Audiobook M4B",
      "categories" => [ { "id" => 3030, "name" => "Audio/Audiobook" } ]
    )

    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "book" }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            [ "Awkward Indexer Title", "Awkward Indexer Title Specific Author" ].include?(req.uri.query_values["query"]) &&
            category_query_param?(req)
        end
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      author_title_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "Specific Author Awkward Indexer Title" &&
            category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ author_title_payload ].to_json
        )

      SearchJob.perform_now(request.id)
      request.reload

      assert_requested author_title_stub
      assert_equal author_title_payload["title"], request.search_results.first.title
      assert_equal "author_title", request.search_results.first.score_breakdown["search_attempt"]
      assert_equal 8, request.search_results.first.score_breakdown["search_penalty"]
    end
  end

  test "stops issuing generic queries once a strong match is found" do
    SettingsService.set(:indexer_search_scope, "strict")
    book = Book.create!(
      title: "Strong First Attempt",
      author: "Solid Author",
      book_type: :audiobook
    )
    request = Request.create!(book: book, user: users(:one), status: :pending)
    strong_payload = prowlarr_result_payload.merge(
      "guid" => "strong-exact-title",
      "title" => "Strong First Attempt Solid Author English Audiobook M4B",
      "categories" => [ { "id" => 3030, "name" => "Audio/Audiobook" } ]
    )

    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "book" }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      exact_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "Strong First Attempt"
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ strong_payload ].to_json
        )

      later_attempts_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] != "Strong First Attempt"
        end
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      SearchJob.perform_now(request.id)
      request.reload

      assert_requested exact_stub
      assert_not_requested later_attempts_stub
      assert_equal strong_payload["title"], request.search_results.first.title
    end
  end

  test "keeps broadening when a penalized match falls below the confidence threshold" do
    SettingsService.set(:indexer_search_scope, "strict")
    book = Book.create!(
      title: "The Perfect Run III",
      author: "Maxime Durand",
      book_type: :audiobook
    )
    request = Request.create!(book: book, user: users(:one), status: :pending)
    weak_payload = prowlarr_result_payload.merge(
      "guid" => "perfect-run-3-weak",
      "title" => "The Perfect Run 3",
      "seeders" => 0,
      "categories" => [ { "id" => 3030, "name" => "Audio/Audiobook" } ]
    )

    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "book" }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] != "The Perfect Run 3" &&
            req.uri.query_values["query"] != "The Perfect Run 3 Maxime Durand"
        end
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      weak_variant_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "The Perfect Run 3"
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ weak_payload ].to_json
        )

      variant_with_author_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "The Perfect Run 3 Maxime Durand"
        end
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      SearchJob.perform_now(request.id)
      request.reload

      threshold = SettingsService.get(:min_match_confidence)
      saved = request.search_results.find_by!(guid: weak_payload["guid"])
      raw_score = saved.confidence_score + saved.score_breakdown["search_penalty"]

      # Sanity-check the scenario: strong before the penalty, weak after it.
      assert_operator raw_score, :>=, threshold
      assert_operator saved.confidence_score, :<, threshold

      assert_requested weak_variant_stub
      assert_requested variant_with_author_stub
    end
  end

  test "keeps results from later attempts when an earlier generic query fails" do
    SettingsService.set(:indexer_search_scope, "strict")
    book = Book.create!(
      title: "Flaky Indexer Book",
      author: "Retry Author",
      book_type: :audiobook
    )
    request = Request.create!(book: book, user: users(:one), status: :pending)
    title_author_payload = prowlarr_result_payload.merge(
      "guid" => "title-author-after-failure",
      "title" => "Flaky Indexer Book Retry Author English Audiobook M4B",
      "categories" => [ { "id" => 3030, "name" => "Audio/Audiobook" } ]
    )

    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "book" }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      failing_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "Flaky Indexer Book"
        end
        .to_return(status: 500, headers: { "Content-Type" => "application/json" }, body: "")

      title_author_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "Flaky Indexer Book Retry Author"
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ title_author_payload ].to_json
        )

      SearchJob.perform_now(request.id)
      request.reload

      assert_requested failing_stub
      assert_requested title_author_stub
      assert_equal title_author_payload["title"], request.search_results.first.title
      assert_equal "title_author", request.search_results.first.score_breakdown["search_attempt"]
    end
  end

  test "marks for attention when generic queries fail authentication" do
    SettingsService.set(:indexer_search_scope, "strict")

    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "book" }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "search" }
        .to_return(status: 401, headers: { "Content-Type" => "application/json" }, body: "")

      SearchJob.perform_now(@request.id)
      @request.reload

      assert @request.attention_needed?
      assert_match(/authentication failed/i, @request.issue_description)
    end
  end

  test "does not generate numeric variants for standalone I in titles" do
    SettingsService.set(:indexer_search_scope, "strict")
    book = Book.create!(
      title: "I Am Legend",
      author: "Richard Matheson",
      book_type: :audiobook
    )
    request = Request.create!(book: book, user: users(:one), status: :pending)

    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      SearchJob.perform_now(request.id)

      assert_not_requested(:get, %r{localhost:9696/api/v1/search}) do |req|
        req.uri.query_values["query"].to_s.include?("1 Am Legend")
      end
    end
  end

  test "tries subtitle-stripped query when full title searches are empty" do
    SettingsService.set(:indexer_search_scope, "strict")
    book = Book.create!(
      title: "Mistborn: The Final Empire",
      author: "Brandon Sanderson",
      book_type: :audiobook
    )
    request = Request.create!(book: book, user: users(:one), status: :pending)
    short_title_payload = prowlarr_result_payload.merge(
      "guid" => "mistborn-short-title",
      "title" => "Mistborn The Final Empire Brandon Sanderson English Audiobook M4B",
      "categories" => [ { "id" => 3030, "name" => "Audio/Audiobook" } ]
    )

    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "book" }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] != "Mistborn Brandon Sanderson"
        end
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      short_title_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "Mistborn Brandon Sanderson"
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ short_title_payload ].to_json
        )

      SearchJob.perform_now(request.id)
      request.reload

      assert_requested short_title_stub
      assert_equal short_title_payload["title"], request.search_results.first.title
      assert_equal "short_title", request.search_results.first.score_breakdown["search_attempt"]
      assert_equal 6, request.search_results.first.score_breakdown["search_penalty"]
    end
  end

  test "keeps low-confidence broad results instead of returning an empty search" do
    book = Book.create!(
      title: "Signal Path",
      author: "Casey Vernon",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: users(:one), status: :pending)
    weak_payload = prowlarr_result_payload.merge(
      "guid" => "signal-path-weak",
      "title" => "Signal Path [German]",
      "seeders" => 0
    )
    video_payload = prowlarr_result_payload.merge(
      "guid" => "signal-path-video",
      "title" => "Signal Path S01E03 1080p WEB-DL x264"
    )

    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "book" }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "search" && category_query_param?(req) }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "search" && !category_query_param?(req) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ weak_payload, video_payload ].to_json
        )

      SearchJob.perform_now(request.id)
      request.reload

      threshold = SettingsService.get(:min_match_confidence)
      titles = request.search_results.pluck(:title)

      assert_includes titles, weak_payload["title"]
      assert_not_includes titles, video_payload["title"]
      assert_operator request.search_results.find_by!(guid: weak_payload["guid"]).confidence_score, :<, threshold
    end
  end

  test "video releases never count as strong matches" do
    SettingsService.set(:indexer_search_scope, "strict")
    book = Book.create!(
      title: "Signal Path",
      author: "Casey Vernon",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: users(:one), status: :pending)
    video_payload = prowlarr_result_payload.merge(
      "guid" => "signal-path-video-strong",
      "title" => "Signal Path Casey Vernon S01E03 1080p WEB-DL x264"
    )

    VCR.turned_off do
      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "book" }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      exact_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "Signal Path"
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ video_payload ].to_json
        )

      later_attempts_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] != "Signal Path"
        end
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

      SearchJob.perform_now(request.id)

      assert_requested exact_stub
      assert_requested later_attempts_stub, at_least_times: 1
    end
  end

  test "uses categoryless Prowlarr fallback when categorized results are weak" do
    broad_payload = prowlarr_result_payload.merge(
      "guid" => "broad-strong-match",
      "title" => "#{@request.book.title} #{@request.book.author} EPUB",
      "categories" => [ { "id" => 7020, "name" => "Books/EBook" } ]
    )
    movie_payload = prowlarr_result_payload.merge(
      "guid" => "broad-movie-match",
      "title" => "#{@request.book.title} #{@request.book.author} Movie",
      "categories" => [ { "id" => 2000, "name" => "Movies" } ]
    )

    VCR.turned_off do
      structured_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "book" }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ prowlarr_result_payload ].to_json
        )

      categorized_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" && category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      broad_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == @request.book.title &&
            !category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ broad_payload, movie_payload ].to_json
        )

      SearchJob.perform_now(@request.id)
      @request.reload

      assert_requested structured_stub
      assert_requested categorized_stub, times: 3
      assert_requested broad_stub
      assert_includes @request.search_results.pluck(:title), broad_payload["title"]
      assert_not_includes @request.search_results.pluck(:title), movie_payload["title"]
    end
  end

  test "uses categoryless Prowlarr complement even when categorized audiobook result is strong" do
    book = Book.create!(
      title: "Strong Audio",
      author: "Narrator Author",
      book_type: :audiobook
    )
    request = Request.create!(book: book, user: users(:one), status: :pending)
    payload = prowlarr_result_payload.merge(
      "guid" => "strong-audiobook-match",
      "title" => "Strong Audio Narrator Author Audiobook M4B"
    )
    broad_payload = prowlarr_result_payload.merge(
      "guid" => "broad-audiobook-match",
      "title" => "Strong Audio Narrator Author Audiobook Complete",
      "categories" => [ { "id" => 3010, "name" => "Audio/MP3" } ]
    )
    movie_payload = prowlarr_result_payload.merge(
      "guid" => "broad-audiobook-movie",
      "title" => "Strong Audio Narrator Author Movie",
      "categories" => [ { "id" => 2000, "name" => "Movies" } ]
    )

    VCR.turned_off do
      structured_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "book" }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ payload ].to_json
        )

      broad_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "Strong Audio" &&
            !category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ broad_payload, movie_payload ].to_json
        )

      SearchJob.perform_now(request.id)
      request.reload

      assert_requested structured_stub
      assert_requested broad_stub
      assert_equal [ broad_payload["title"], payload["title"] ].sort, request.search_results.pluck(:title).sort
      assert_not_includes request.search_results.pluck(:title), movie_payload["title"]
    end
  end

  test "keeps categorized results when categoryless Prowlarr complement fails" do
    payload = prowlarr_result_payload.merge(
      "guid" => "categorized-strong-match",
      "title" => "#{@request.book.title} #{@request.book.author} EPUB"
    )

    VCR.turned_off do
      structured_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "book" }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ payload ].to_json
        )

      categorized_generic_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == @request.book.title &&
            category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      broad_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == @request.book.title &&
            !category_query_param?(req)
        end
        .to_raise(Faraday::TimeoutError.new("timeout"))

      SearchJob.perform_now(@request.id)
      @request.reload

      assert_requested structured_stub
      assert_requested categorized_generic_stub
      assert_requested broad_stub
      assert_equal [ payload["title"] ], @request.search_results.pluck(:title)
    end
  end

  test "does not use categoryless Prowlarr complement in strict scope" do
    SettingsService.set(:indexer_search_scope, "strict")
    payload = prowlarr_result_payload.merge(
      "guid" => "strict-categorized-match",
      "title" => "#{@request.book.title} #{@request.book.author} EPUB"
    )

    VCR.turned_off do
      structured_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "book" && category_query_param?(req) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ payload ].to_json
        )

      categorized_generic_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == @request.book.title &&
            category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      broad_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "search" && !category_query_param?(req) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      SearchJob.perform_now(@request.id)
      @request.reload

      assert_requested structured_stub
      assert_requested categorized_generic_stub
      assert_not_requested broad_stub
      assert_equal [ payload["title"] ], @request.search_results.pluck(:title)
    end
  end

  test "uses custom category IDs for Prowlarr scope" do
    SettingsService.set(:indexer_search_scope, "custom")
    SettingsService.set(:indexer_custom_ebook_categories, "7050")

    VCR.turned_off do
      structured_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "book" &&
            req.uri.query.to_s.include?("categories=7050")
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ prowlarr_result_payload ].to_json
        )

      stub_prowlarr_generic_search_empty

      SearchJob.perform_now(@request.id)
      @request.reload

      assert_requested structured_stub
      assert @request.search_results.any?
    end
  end

  test "uses no category parameter for unrestricted Prowlarr scope" do
    SettingsService.set(:indexer_search_scope, "unrestricted")
    ebook_payload = prowlarr_result_payload.merge(
      "guid" => "unrestricted-ebook",
      "title" => "#{@request.book.title} #{@request.book.author} EPUB",
      "categories" => [ { "id" => 7020, "name" => "Books/EBook" } ]
    )
    movie_payload = prowlarr_result_payload.merge(
      "guid" => "unrestricted-movie",
      "title" => "#{@request.book.title} #{@request.book.author} Movie",
      "categories" => [ { "id" => 2000, "name" => "Movies" } ]
    )

    VCR.turned_off do
      structured_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "book" &&
            !category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ ebook_payload, movie_payload ].to_json
        )

      generic_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with { |req| req.uri.query_values["type"] == "search" && !category_query_param?(req) }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      SearchJob.perform_now(@request.id)
      @request.reload

      assert_requested structured_stub
      assert_requested generic_stub
      assert_equal [ ebook_payload["title"] ], @request.search_results.pluck(:title)
    end
  end

  test "unrestricted Prowlarr audiobook search falls back when strong structured results have incompatible categories" do
    SettingsService.set(:indexer_search_scope, "unrestricted")
    book = Book.create!(
      title: "Audio Scope",
      author: "Narrator Author",
      book_type: :audiobook
    )
    request = Request.create!(book: book, user: users(:one), status: :pending)
    movie_payload = prowlarr_result_payload.merge(
      "guid" => "unrestricted-audio-movie",
      "title" => "Audio Scope Narrator Author Audiobook M4B",
      "categories" => [ { "id" => 2000, "name" => "Movies" } ]
    )
    audiobook_payload = prowlarr_result_payload.merge(
      "guid" => "unrestricted-audio-generic",
      "title" => "Audio Scope Narrator Author Audiobook M4B",
      "categories" => [ { "id" => 3010, "name" => "Audio/MP3" } ]
    )

    VCR.turned_off do
      structured_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "book" &&
            !category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ movie_payload ].to_json
        )

      generic_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "Audio Scope" &&
            !category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ audiobook_payload ].to_json
        )

      SearchJob.perform_now(request.id)
      request.reload

      assert_requested structured_stub
      assert_requested generic_stub
      assert_equal [ audiobook_payload["title"] ], request.search_results.pluck(:title)
    end
  end

  test "supplements partial Prowlarr ebook results with generic title search" do
    book = Book.create!(
      title: "Frieren: Beyond Journey's End, Vol. 1",
      author: "Kanehito Yamada",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: users(:one), status: :pending)
    structured_payload = prowlarr_result_payload.merge(
      "guid" => "mam-frieren-prelude",
      "title" => "Frieren: Beyond Journey's End -Prelude-, Vol. 1 by Mei Hachimoku [ENG / EPUB]",
      "indexer" => "MyAnonaMouse"
    )
    generic_payload = prowlarr_result_payload.merge(
      "guid" => "nyaa-frieren-v01",
      "title" => "Frieren - Beyond Journey's End v01 (2021) (Digital) (danke-Empire)",
      "indexer" => "Nyaa.si"
    )

    VCR.turned_off do
      structured_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          query = req.uri.query_values["query"]
          req.uri.query_values["type"] == "book" &&
            query.include?("{title:Frieren: Beyond Journey's End, Vol. 1}") &&
            query.include?("{author:Kanehito Yamada}")
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ structured_payload ].to_json
        )

      generic_stub = stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "Frieren: Beyond Journey's End, Vol. 1" &&
            category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [ generic_payload ].to_json
        )

      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] != "Frieren: Beyond Journey's End, Vol. 1" &&
            category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] == "Frieren: Beyond Journey's End, Vol. 1" &&
            !category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      stub_request(:get, %r{localhost:9696/api/v1/search})
        .with do |req|
          req.uri.query_values["type"] == "search" &&
            req.uri.query_values["query"] != "Frieren: Beyond Journey's End, Vol. 1" &&
            !category_query_param?(req)
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      SearchJob.perform_now(request.id)
      request.reload

      assert_requested structured_stub
      assert_requested generic_stub
      assert_equal [
        "Frieren - Beyond Journey's End v01 (2021) (Digital) (danke-Empire)",
        "Frieren: Beyond Journey's End -Prelude-, Vol. 1 by Mei Hachimoku [ENG / EPUB]"
      ].sort,
        request.search_results.pluck(:title).sort
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
      stub_prowlarr_generic_search_empty

      SearchJob.perform_now(request.id)
      request.reload

      assert request.search_results.any?
    end
  end

  test "starts generic text search with title-only query for Jackett" do
    SettingsService.set(:indexer_provider, "jackett")
    SettingsService.set(:jackett_url, "http://localhost:9117")
    SettingsService.set(:jackett_api_key, "jackett-key")

    body = jackett_result_xml(
      title: "#{@request.book.title} #{@request.book.author} EPUB",
      guid: "jackett-title-first"
    )

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

  test "uses categoryless Jackett fallback when categorized search is weak" do
    SettingsService.set(:indexer_provider, "jackett")
    SettingsService.set(:jackett_url, "http://localhost:9117")
    SettingsService.set(:jackett_api_key, "jackett-key")

    empty_body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
        <channel></channel>
      </rss>
    XML
    result_body = jackett_result_xml(
      title: "#{@request.book.title} #{@request.book.author} EPUB",
      guid: "jackett-broad-guid"
    )

    VCR.turned_off do
      categorized_stub = stub_request(:get, %r{localhost:9117/api/v2\.0/indexers/all/results/torznab/api})
        .with do |req|
          req.uri.query_values["t"] == "search" && category_query_param?(req)
        end
        .to_return(status: 200, body: empty_body, headers: { "Content-Type" => "application/xml" })

      broad_stub = stub_request(:get, %r{localhost:9117/api/v2\.0/indexers/all/results/torznab/api})
        .with do |req|
          req.uri.query_values["t"] == "search" &&
            req.uri.query_values["q"] == @request.book.title &&
            !category_query_param?(req)
        end
        .to_return(status: 200, body: result_body, headers: { "Content-Type" => "application/xml" })

      SearchJob.perform_now(@request.id)
      @request.reload

      assert_requested categorized_stub, times: 3
      assert_requested broad_stub
      assert_equal "#{@request.book.title} #{@request.book.author} EPUB", @request.search_results.first.title
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
      [ result ]
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

    ZLibraryClient.stub :search, [ result ] do
      assert_nothing_raised do
        SearchJob.perform_now(@request.id)
      end
    end

    @request.reload
    assert_equal SearchResult::SOURCE_ZLIBRARY, @request.search_results.first.source
    assert @request.attention_needed?
  end

  test "includes z-library results when anna archive returns no results" do
    SettingsService.set(:prowlarr_api_key, "")
    SettingsService.set(:anna_archive_enabled, true)
    SettingsService.set(:anna_archive_api_key, "aa-key")
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

    AnnaArchiveClient.stub :search, [] do
      ZLibraryClient.stub :search, [ result ] do
        SearchJob.perform_now(@request.id)
      end
    end

    @request.reload
    saved_result = @request.search_results.first
    assert_equal SearchResult::SOURCE_ZLIBRARY, saved_result.source
    assert_equal "999:deadbeef", saved_result.guid
  end

  test "includes results from both anna archive and z-library" do
    SettingsService.set(:prowlarr_api_key, "")
    SettingsService.set(:anna_archive_enabled, true)
    SettingsService.set(:anna_archive_api_key, "aa-key")
    SettingsService.set(:zlibrary_enabled, true)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "reader@example.com")
    SettingsService.set(:zlibrary_password, "secret")

    anna_result = AnnaArchiveClient::Result.new(
      md5: "abc123def456",
      title: @request.book.title,
      author: @request.book.author,
      year: 2019,
      file_type: "epub",
      file_size: "5 MB",
      language: "en"
    )
    zlibrary_result = ZLibraryClient::Result.new(
      id: "999",
      hash: "deadbeef",
      title: "Z-Library Result",
      author: @request.book.author,
      year: 2024,
      file_type: "epub",
      file_size: 5_452_595,
      language: "en"
    )

    AnnaArchiveClient.stub :search, [ anna_result ] do
      ZLibraryClient.stub :search, [ zlibrary_result ] do
        SearchJob.perform_now(@request.id)
      end
    end

    @request.reload
    sources = @request.search_results.pluck(:source)
    assert_includes sources, SearchResult::SOURCE_ANNA_ARCHIVE
    assert_includes sources, SearchResult::SOURCE_ZLIBRARY
  end

  test "marks request not found when anna archive and z-library return no results" do
    SettingsService.set(:prowlarr_api_key, "")
    SettingsService.set(:anna_archive_enabled, true)
    SettingsService.set(:anna_archive_api_key, "aa-key")
    SettingsService.set(:zlibrary_enabled, true)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "reader@example.com")
    SettingsService.set(:zlibrary_password, "secret")

    AnnaArchiveClient.stub :search, [] do
      ZLibraryClient.stub :search, [] do
        SearchJob.perform_now(@request.id)
      end
    end

    @request.reload
    assert @request.not_found?
    direct_sources = [ SearchResult::SOURCE_ANNA_ARCHIVE, SearchResult::SOURCE_ZLIBRARY ]
    assert @request.search_results.none? { |result| direct_sources.include?(result.source) }
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

  test "includes librivox results for audiobook requests" do
    SettingsService.set(:prowlarr_api_key, "")
    SettingsService.set(:librivox_enabled, true)
    book = books(:audiobook_acquired)
    request = Request.create!(book: book, user: users(:one), status: :pending, language: "en")
    result = LibrivoxClient::Result.new(
      id: "253",
      title: "Pride and Prejudice",
      author: "Jane Austen",
      language: "en",
      year: "1813",
      file_type: "audiobook zip",
      download_url: "https://archive.org/compress/pride_and_prejudice_librivox/formats=64KBPS%20MP3",
      info_url: "https://librivox.org/pride-and-prejudice-by-jane-austen/",
      duration: "13:06:44"
    )

    LibrivoxClient.stub :search, ->(title:, author:, language: nil, **) {
      assert_equal book.title, title
      assert_equal book.author, author
      assert_equal "en", language
      [ result ]
    } do
      SearchJob.perform_now(request.id)
    end

    request.reload
    saved_result = request.search_results.first
    assert_equal SearchResult::SOURCE_LIBRIVOX, saved_result.source
    assert_equal "librivox:253", saved_result.guid
    assert_equal "LibriVox", saved_result.indexer
    assert_equal result.download_url, saved_result.download_url
    assert_includes saved_result.title, "[AUDIOBOOK ZIP]"
  end

  test "includes Project Gutenberg results for ebook requests" do
    SettingsService.set(:prowlarr_api_key, "")
    SettingsService.set(:gutenberg_enabled, true)
    result = GutenbergClient::Result.new(
      id: "1342",
      title: "Pride and Prejudice",
      author: "Austen, Jane",
      language: "en",
      year: nil,
      file_type: "epub",
      download_url: "https://www.gutenberg.org/ebooks/1342.epub3.images?download=1",
      info_url: "https://www.gutenberg.org/ebooks/1342"
    )

    GutenbergClient.stub :search, ->(title:, author:, language: nil, **) {
      assert_equal @request.book.title, title
      assert_equal @request.book.author, author
      assert_equal "en", language
      [ result ]
    } do
      SearchJob.perform_now(@request.id)
    end

    @request.reload
    saved_result = @request.search_results.first
    assert_equal SearchResult::SOURCE_GUTENBERG, saved_result.source
    assert_equal "gutenberg:1342", saved_result.guid
    assert_equal "Project Gutenberg", saved_result.indexer
    assert_equal result.download_url, saved_result.download_url
    assert_equal "en", saved_result.detected_language
    assert_includes saved_result.title, "[EPUB]"
  end

  test "includes custom acquisition provider results" do
    SettingsService.set(:prowlarr_api_key, "")
    provider = AcquisitionProvider.create!(
      name: "Local Provider",
      url: "http://provider.test",
      supports_ebooks: true,
      supports_audiobooks: false
    )

    VCR.turned_off do
      stub_request(:post, "http://provider.test/search")
        .with do |request|
          body = JSON.parse(request.body)
          body["book"]["title"] == @request.book.title &&
            body["book"]["book_type"] == "ebook"
        end
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            results: [
              {
                id: "provider-1",
                title: "The Pending Ebook",
                author: "Another Author",
                format: "epub",
                language: "en",
                size_bytes: 1000,
                download_type: "direct",
                info_url: "https://provider.test/books/provider-1"
              }
            ]
          }.to_json
        )

      SearchJob.perform_now(@request.id)
    end

    @request.reload
    saved_result = @request.search_results.first
    assert_equal SearchResult::SOURCE_CUSTOM, saved_result.source
    assert_equal provider, saved_result.acquisition_provider
    assert_equal "provider-1", saved_result.provider_result_id
    assert_equal "custom:#{provider.id}:provider-1", saved_result.guid
    assert_equal "direct", saved_result.download_type
    assert saved_result.downloadable?
  end

  test "skips unavailable custom acquisition provider results" do
    SettingsService.set(:prowlarr_api_key, "")
    provider = AcquisitionProvider.create!(
      name: "Availability Provider",
      url: "http://availability-provider.test",
      supports_ebooks: true,
      supports_audiobooks: false
    )

    VCR.turned_off do
      stub_request(:post, "http://availability-provider.test/search")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            results: [
              {
                id: "provider-available",
                title: "Available Provider Result",
                format: "epub",
                direct_url: "https://files.test/available.epub",
                availability: "available"
              },
              {
                id: "provider-unavailable",
                title: "Unavailable Provider Result",
                format: "epub",
                direct_url: "https://files.test/unavailable.epub",
                availability: "temporarily_unavailable"
              }
            ]
          }.to_json
        )

      SearchJob.perform_now(@request.id)
    end

    @request.reload
    assert_equal [ "provider-available" ], @request.search_results.pluck(:provider_result_id)
    saved_result = @request.search_results.first
    assert_equal provider, saved_result.acquisition_provider
    assert_equal "direct", saved_result.download_type
    assert saved_result.downloadable?
  end

  test "skips Project Gutenberg for audiobook requests" do
    SettingsService.set(:prowlarr_api_key, "")
    SettingsService.set(:gutenberg_enabled, true)
    book = books(:audiobook_acquired)
    request = Request.create!(book: book, user: users(:one), status: :pending)

    GutenbergClient.stub :search, ->(*) { flunk "Project Gutenberg should only be searched for ebooks" } do
      SearchJob.perform_now(request.id)
    end

    request.reload
    assert request.attention_needed?
    assert_includes request.issue_description, "No search sources configured"
  end

  test "skips librivox for ebook requests" do
    SettingsService.set(:prowlarr_api_key, "")
    SettingsService.set(:librivox_enabled, true)

    LibrivoxClient.stub :search, ->(*) { flunk "LibriVox should only be searched for audiobooks" } do
      SearchJob.perform_now(@request.id)
    end

    @request.reload
    assert @request.attention_needed?
    assert_includes @request.issue_description, "No search sources configured"
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

  test "uses newznab when explicitly selected as the indexer provider" do
    SettingsService.set(:indexer_provider, "newznab")
    SettingsService.set(:newznab_url, "http://localhost:5076")
    SettingsService.set(:newznab_api_key, "newznab-key")

    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/">
        <channel>
          <item>
            <title>Newznab Search Result</title>
            <guid>newznab-guid-1</guid>
            <link>https://example.com/details/1</link>
            <enclosure url="http://localhost:5076/getnzb/api/1?apikey=newznab-key" length="12345" type="application/x-nzb" />
            <newznab:attr name="hydraIndexerName" value="NZBHydra Books" />
          </item>
        </channel>
      </rss>
    XML

    VCR.turned_off do
      stub_request(:get, "http://localhost:5076/api")
        .with(query: hash_including("apikey" => "newznab-key", "t" => "search"))
        .to_return(status: 200, body: body, headers: { "Content-Type" => "application/xml" })

      SearchJob.perform_now(@request.id)
      @request.reload

      assert @request.search_results.any?
      assert_equal SearchResult::SOURCE_NEWZNAB, @request.search_results.first.source
      assert_equal "NZBHydra Books", @request.search_results.first.indexer
      assert @request.search_results.first.usenet?
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

  def stub_prowlarr_generic_search_empty
    stub_request(:get, %r{localhost:9696/api/v1/search})
      .with { |req| req.uri.query_values["type"] == "search" }
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

  def category_query_param?(request)
    request.uri.query.to_s.match?(/(?:^|&)(?:categories(?:%5B%5D)?|cat)=/)
  end

  def jackett_result_xml(title:, guid:)
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed">
        <channel>
          <item>
            <title>#{title}</title>
            <guid>#{guid}</guid>
            <link>https://example.com/details/#{guid}</link>
            <jackettindexer>JackettBooks</jackettindexer>
            <enclosure url="magnet:?xt=urn:btih:#{guid}" length="12345" type="application/x-bittorrent" />
            <torznab:attr name="seeders" value="12" />
          </item>
        </channel>
      </rss>
    XML
  end
end
