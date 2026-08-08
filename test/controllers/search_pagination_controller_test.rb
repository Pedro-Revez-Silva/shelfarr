# frozen_string_literal: true

require "test_helper"

class SearchPaginationControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @user = users(:one)
    sign_in_as(@user)
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "stream rebuilds untruncated pages as providers finish without duplicate provider calls" do
    candidates = 25.times.map { |index| candidate(index) }
    provider_calls = Hash.new(0)
    aggregate_sizes = []
    provider_search = lambda do |_query, **options, &block|
      assert_nil options[:limit]
      provider_calls["openlibrary"] += 1
      block.call("openlibrary", [ :first ], false)
      provider_calls["google_books"] += 1
      block.call("google_books", [ :second ], false)
    end
    aggregate = lambda do |raw_results, limit:, content_kind:|
      assert_equal SearchResultSnapshot::MAX_RESULTS, limit
      assert_nil content_kind
      aggregate_sizes << raw_results.size
      raw_results.size == 1 ? candidates.first(10) : candidates
    end

    MetadataService.stub(:enabled_metadata_providers, %w[openlibrary google_books]) do
      MetadataService.stub(:each_provider_search, provider_search) do
        MetadataService.stub(:aggregate_provider_results, aggregate) do
          get search_results_stream_path, params: { q: "many books", page: 1 }
        end
      end
    end

    assert_response :success
    assert_equal({ "openlibrary" => 1, "google_books" => 1 }, provider_calls)
    assert_equal [ 1, 2 ], aggregate_sizes
    assert_operator response.body.scan('<turbo-stream action="update" target="search-results">').size, :>=, 3
    assert_includes response.body, "25 results for"
    assert_includes response.body, 'data-search-page-count="2"'
    assert_includes response.body, 'data-search-has-next="true"'
    assert_includes response.body, 'data-search-complete="true"'
    assert_includes response.body, "Book 19"
    assert_not_includes response.body.split('<turbo-stream action="update" target="search-results">').last, "Book 20"
    assert_select "a[href*='q=many+books'][href*='page=2']", text: "Next"
  end

  test "snapshot endpoint returns the last aggregate page without calling providers" do
    token = completed_snapshot(25)

    MetadataService.stub(:each_provider_search, ->(*) { flunk "snapshot navigation called metadata providers" }) do
      get search_results_snapshot_path,
        params: { snapshot_id: token, q: "many books", content_kind: "book", page: 2 },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_includes response.body, "Book 20"
    assert_includes response.body, "Book 24"
    assert_not_includes response.body, "Book 19"
    assert_includes response.body, 'data-search-page="2"'
    assert_includes response.body, 'data-search-page-count="2"'
    assert_includes response.body, 'data-search-has-next="false"'
    assert_select "nav[aria-label='Search result pages']"
    assert_select "[aria-current='page'][aria-label='Page 2']", text: "2"
    assert_select "a[href*='page=1']", text: "Previous"
    assert_select "[aria-disabled='true']", text: "Next"
  end

  test "snapshot endpoint canonicalizes an out-of-range completed page" do
    token = completed_snapshot(25)

    get search_results_snapshot_path,
      params: { snapshot_id: token, q: "many books", content_kind: "book", page: 10 },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "[data-search-state][data-search-page='2'][data-search-page-count='2']"
    assert_select "[aria-current='page'][aria-label='Page 2']", text: "2"
    assert_select "a[href*='page=1']", text: "Previous"
    assert_select "h3", text: "Book 20"
    assert_select "h3", text: "Book 0", count: 0
  end

  test "synchronous results aggregate to the bound and render only the requested slice" do
    search = lambda do |_query, aggregate_limit:, **_options|
      assert_equal SearchResultSnapshot::MAX_RESULTS, aggregate_limit
      25.times.map { |index| candidate(index) }
    end

    MetadataService.stub(:search, search) do
      get search_results_path,
        params: { q: "many books", content_kind: "book", page: 2 },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_select "[data-search-state][data-search-page='2'][data-search-page-count='2']"
    assert_select "h3", count: 5
    assert_select "h3", text: "Book 20"
    assert_select "h3", text: "Book 19", count: 0
  end

  test "no-JavaScript Next follows the synchronous endpoint and renders only page two" do
    calls = 0
    search = lambda do |_query, aggregate_limit:, **_options|
      calls += 1
      assert_equal SearchResultSnapshot::MAX_RESULTS, aggregate_limit
      25.times.map { |index| candidate(index) }
    end

    MetadataService.stub(:search, search) do
      get search_results_path, params: { q: "many books", content_kind: "book", page: 1 }
      assert_response :success
      next_href = css_select("a").find { |link| link.text == "Next" }["href"]
      assert URI(next_href).path.end_with?(search_results_path)

      get next_href
    end

    assert_response :success
    assert_equal 2, calls
    assert_select "[data-search-state][data-search-page='2'][data-search-page-count='2']"
    assert_select "h3", count: 5
    assert_select "h3", text: "Book 20"
    assert_select "h3", text: "Book 19", count: 0
  end

  test "no-JavaScript out-of-range pages fail without repeating provider search" do
    calls = 0
    search = lambda do |_query, aggregate_limit:, **_options|
      calls += 1
      assert_equal SearchResultSnapshot::MAX_RESULTS, aggregate_limit
      25.times.map { |index| candidate(index) }
    end

    MetadataService.stub(:search, search) do
      get search_results_path, params: { q: "many books", content_kind: "book", page: 10 }
    end

    assert_response :not_found
    assert_equal 1, calls
  end

  test "Turbo out-of-range pages canonicalize in place without redirecting" do
    search = lambda do |_query, aggregate_limit:, **_options|
      assert_equal SearchResultSnapshot::MAX_RESULTS, aggregate_limit
      25.times.map { |index| candidate(index) }
    end

    MetadataService.stub(:search, search) do
      get search_results_path,
        params: { q: "many books", content_kind: "book", page: 10 },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_select "[data-search-state][data-search-page='2'][data-search-page-count='2']"
  end

  test "no-JavaScript invalid page values fail before calling providers" do
    [ "", " ", "0", "-5", "+1", "1_0", "999", "invalid" ].each do |page|
      MetadataService.stub(:search, ->(*) { flunk "invalid page called metadata providers" }) do
        get search_results_path, params: { q: "many books", page: page }
      end

      assert_response :not_found
    end
  end

  test "no-JavaScript unavailable page fails when the search has no results" do
    calls = 0
    MetadataService.stub(:search, ->(*) { calls += 1; [] }) do
      get search_results_path, params: { q: "missing book", page: 2 }
    end

    assert_response :not_found
    assert_equal 1, calls
  end

  test "snapshot endpoint fails safely for mismatched and foreign snapshots" do
    token = completed_snapshot(1)

    get search_results_snapshot_path,
      params: { snapshot_id: token, q: "different", content_kind: "book", page: 1 }
    assert_response :not_found

    sign_out
    sign_in_as(users(:two))
    get search_results_snapshot_path,
      params: { snapshot_id: token, q: "many books", content_kind: "book", page: 1 }
    assert_response :not_found
  end

  test "expired snapshot endpoint fails safely without providers" do
    token = completed_snapshot(1)

    travel SearchResultSnapshot::TTL + 1.second do
      MetadataService.stub(:each_provider_search, ->(*) { flunk "expired snapshot called metadata providers" }) do
        get search_results_snapshot_path,
          params: { snapshot_id: token, q: "many books", content_kind: "book", page: 1 }
      end
    end

    assert_response :not_found
    assert_equal "private, no-store", response.headers["Cache-Control"]
  end

  test "stream exposes partial provider failures in the completed snapshot state" do
    provider_search = lambda do |_query, **_options, &block|
      block.call("openlibrary", [ :result ], false)
      block.call("google_books", [], true)
    end

    MetadataService.stub(:enabled_metadata_providers, %w[openlibrary google_books]) do
      MetadataService.stub(:each_provider_search, provider_search) do
        MetadataService.stub(:aggregate_provider_results, [ candidate(1) ]) do
          get search_results_stream_path, params: { q: "partial" }
        end
      end
    end

    assert_response :success
    assert_includes response.body, "Some metadata providers could not be reached: Google Books."
    assert_includes response.body, 'data-search-failed-providers="Google Books"'
  end

  test "stream renders all-provider failure on the requested page and clears loading state" do
    provider_search = lambda do |_query, **_options, &block|
      block.call("openlibrary", [], true)
      block.call("google_books", [], true)
    end

    MetadataService.stub(:enabled_metadata_providers, %w[openlibrary google_books]) do
      MetadataService.stub(:each_provider_search, provider_search) do
        MetadataService.stub(:aggregate_provider_results, []) do
          get search_results_stream_path, params: { q: "failed", content_kind: "book", page: 2 }
        end
      end
    end

    assert_response :success
    final = response.body.split('<turbo-stream action="update" target="search-results">').last
    assert_includes final, "Unable to connect to metadata service"
    assert_includes final, 'data-search-query="failed"'
    assert_includes final, 'data-search-content-kind="book"'
    assert_includes final, 'data-search-page="2"'
    assert_includes final, 'data-search-complete="true"'
  end

  test "unexpected stream errors retain requested state" do
    provider_search = lambda do |_query, **_options, &block|
      block.call("openlibrary", [ :result ], false)
    end

    MetadataService.stub(:enabled_metadata_providers, %w[openlibrary]) do
      MetadataService.stub(:each_provider_search, provider_search) do
        MetadataService.stub(:aggregate_provider_results, ->(*) { raise ArgumentError, "bad aggregate" }) do
          get search_results_stream_path, params: { q: "broken", content_kind: "graphic", page: 3 }
        end
      end
    end

    assert_response :success
    final = response.body.split('<turbo-stream action="update" target="search-results">').last
    assert_includes final, "Search failed. Please try again."
    assert_includes final, 'data-search-query="broken"'
    assert_includes final, 'data-search-content-kind="graphic"'
    assert_includes final, 'data-search-page="3"'
    assert_includes final, 'data-search-complete="true"'
  end

  test "snapshot pages refresh existing-library enrichment" do
    token = completed_snapshot(1)
    %i[ebook audiobook].each do |book_type|
      Book.create!(
        title: "Book 0",
        book_type: book_type,
        open_library_work_id: "work-0",
        file_path: "/library/#{book_type}/book-0"
      )
    end

    get search_results_snapshot_path,
      params: { snapshot_id: token, q: "many books", content_kind: "book", page: 1 },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "span", text: "In library"
    assert_select "a", text: "Request", count: 0
  end

  test "direct stream canonicalizes page ten to the last discovered page" do
    provider_search = lambda do |_query, **_options, &block|
      block.call("openlibrary", [ :result ], false)
    end

    MetadataService.stub(:enabled_metadata_providers, %w[openlibrary]) do
      MetadataService.stub(:each_provider_search, provider_search) do
        MetadataService.stub(:aggregate_provider_results, 25.times.map { |index| candidate(index) }) do
          get search_results_stream_path, params: { q: "many books", page: 10 }
        end
      end
    end

    assert_response :success
    final = response.body.split('<turbo-stream action="update" target="search-results">').last
    assert_includes final, 'data-search-page="2"'
    assert_includes final, 'aria-label="Page 2"'
    assert_includes final, "page=1"
    assert_includes final, "Book 20"
  end

  test "direct page parameters are normalized and included in the initial search state" do
    get search_path, params: { q: "many books", content_kind: "comic", page: 2 }

    assert_response :success
    assert_select "[data-controller='search'][data-search-page-value='2'][data-search-initial-search-value='true']"
    assert_select "[data-search-snapshot-url-value='#{search_results_snapshot_path}']"
    assert_select "option[value='graphic'][selected]"
    assert_select "#search-results[aria-busy='true']"
    assert_select "label[for='metadata-search-query']", text: /Search by title/
    assert_select "input#metadata-search-query[aria-label]", count: 0
    assert_select "label[for='metadata-search-content-kind']", text: "Content type"
  end

  private

  def completed_snapshot(size)
    token = SearchResultSnapshot.create(
      user: @user,
      query: "many books",
      content_kind: "book",
      provider_count: 2
    )
    SearchResultSnapshot.write(
      user: @user,
      id: token,
      query: "many books",
      content_kind: "book",
      results: size.times.map { |index| candidate(index) },
      complete: true,
      failed_providers: [],
      provider_count: 2
    )
    token
  end

  def candidate(index)
    MetadataSearch::Candidate.new(
      canonical_key: "openlibrary:work-#{index}",
      title: "Book #{index}",
      author: "Author",
      year: 2020,
      description: nil,
      cover_url: nil,
      series_name: nil,
      series_position: nil,
      has_ebook: true,
      has_audiobook: nil,
      sources: [ {
        source: "openlibrary",
        source_id: "work-#{index}",
        source_name: "Open Library",
        source_url: nil,
        work_id: "openlibrary:work-#{index}"
      } ],
      editions: [],
      confidence: 70,
      content_kind: "book"
    )
  end
end
