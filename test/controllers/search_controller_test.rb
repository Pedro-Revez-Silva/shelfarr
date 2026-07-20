# frozen_string_literal: true

require "test_helper"

class SearchControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
    @original_metadata_source = SettingsService.get(:metadata_source)
    @original_metadata_provider_priority = SettingsService.get(:metadata_provider_priority)
    @original_hardcover_api_token = SettingsService.get(:hardcover_api_token)
    @original_hardcover_enabled = SettingsService.get(:hardcover_enabled)
    @original_google_books_enabled = SettingsService.get(:google_books_enabled)
    @original_open_library_enabled = SettingsService.get(:open_library_enabled)
    MetadataProviderStatus.delete_all
    HardcoverClient.reset_connection!
    GoogleBooksClient.reset_connection!
    OpenLibraryClient.reset_connection!
  end

  teardown do
    SettingsService.set(:metadata_source, @original_metadata_source || "auto")
    SettingsService.set(:metadata_provider_priority, @original_metadata_provider_priority || "hardcover,openlibrary,google_books")
    SettingsService.set(:hardcover_api_token, @original_hardcover_api_token.to_s)
    SettingsService.set(:hardcover_enabled, @original_hardcover_enabled.nil? ? true : @original_hardcover_enabled)
    SettingsService.set(:google_books_enabled, @original_google_books_enabled.nil? ? true : @original_google_books_enabled)
    SettingsService.set(:open_library_enabled, @original_open_library_enabled.nil? ? true : @original_open_library_enabled)
    MetadataProviderStatus.delete_all
    HardcoverClient.reset_connection!
    GoogleBooksClient.reset_connection!
    OpenLibraryClient.reset_connection!
  end

  test "index requires authentication" do
    sign_out
    get search_path
    assert_response :redirect
  end

  test "index shows search form" do
    get search_path
    assert_response :success
    assert_select "input[type='text']"
    assert_select "[data-controller='search'][data-search-debounce-value='700']"
    assert_select "[data-search-stream-url-value='#{search_results_stream_path}']"
  end

  test "index normalizes legacy graphic filters" do
    get search_path, params: { content_kind: "manga" }

    assert_response :success
    assert_select "option[value='graphic'][selected]", text: "Comics & Manga"
    assert_select "option[value='manga']", count: 0
    assert_select "option[value='comic']", count: 0
  end

  test "results normalizes legacy graphic filters before searching" do
    MetadataService.stub(:search, ->(_query, content_kind:) {
      assert_equal "graphic", content_kind
      []
    }) do
      get search_results_path, params: { q: "akira", content_kind: "comic" }
    end

    assert_response :success
  end

  test "results returns search results" do
    GoogleBooksClient.stub(:search, []) do
      with_cassette("open_library/search_harry_potter") do
        get search_results_path, params: { q: "harry potter" }
        assert_response :success
      end
    end
  end

  test "result navigation only encodes bounded identity metadata in URLs" do
    long_value = "Long provider metadata " * 1_000
    result = MetadataSearch::Candidate.new(
      canonical_key: "google_books:gb-long-metadata",
      title: long_value,
      author: long_value,
      year: 2026,
      description: long_value,
      cover_url: "https://example.com/#{long_value}",
      series_name: long_value,
      series_position: long_value,
      has_audiobook: nil,
      has_ebook: true,
      sources: [
        {
          source: "google_books",
          source_id: "gb-long-metadata",
          source_name: "Google Books",
          source_url: nil,
          work_id: "google_books:gb-long-metadata"
        }
      ],
      editions: [],
      confidence: 100,
      collection_source: "hardcover",
      collection_id: "series-123",
      collection_title: long_value
    )

    MetadataService.stub(:search, [ result ]) do
      get search_results_path, params: { q: "long description" }
    end

    assert_response :success
    assert_select "a[href^='#{new_request_path}']", text: "Request" do |links|
      assert_compact_metadata_url links.first["href"]
    end
    assert_select "a[data-turbo-frame='modal']" do |links|
      links.each { |link| assert_compact_metadata_url(link["href"]) }
    end
  end

  test "results keep an awaiting purchase work marked as requested" do
    source_id = "OL_SEARCH_AWAITING_PURCHASE"
    ebook = Book.create!(
      title: "Awaiting Store Purchase",
      book_type: :ebook,
      open_library_work_id: source_id
    )
    Request.create!(book: ebook, user: @user, status: :awaiting_purchase)
    Book.create!(
      title: "Awaiting Store Purchase",
      book_type: :audiobook,
      open_library_work_id: source_id,
      file_path: "/audiobooks/awaiting-store-purchase"
    )
    result = metadata_result(
      source_id: source_id,
      title: "Awaiting Store Purchase",
      author: "Store Author",
      year: 2026
    )

    MetadataService.stub(:search, [ result ]) do
      get search_results_path, params: { q: "Awaiting Store Purchase" }
    end

    assert_response :success
    assert_select "span", text: "Requested"
    assert_select "a", text: "Request", count: 0
  end

  test "results with empty query returns empty results" do
    get search_results_path, params: { q: "" }
    assert_response :success
  end

  test "results handles turbo stream format" do
    GoogleBooksClient.stub(:search, []) do
      with_cassette("open_library/search_fiction") do
        get search_results_path, params: { q: "fiction" }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
        assert_response :success
        assert_match "turbo-stream", response.body
      end
    end
  end

  test "results renders connection error message" do
    MetadataService.stub(:search, ->(_) { raise GoogleBooksClient::ConnectionError, "network down" }) do
      get search_results_path, params: { q: "fiction" }
    end

    assert_response :success
    assert_match "Unable to connect to metadata service", response.body
  end

  test "results renders generic metadata error message" do
    MetadataService.stub(:search, ->(_) { raise GoogleBooksClient::Error, "api down" }) do
      get search_results_path, params: { q: "fiction" }
    end

    assert_response :success
    assert_match "Search failed. Please try again.", response.body
  end

  test "results shows related titles when matching audiobookshelf items exist" do
    LibraryItem.destroy_all
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-1",
      title: "The Hobbit",
      subtitle: "There and Back Again",
      author: "J.R.R. Tolkien",
      narrator: "Andy Serkis",
      series: "Middle-earth",
      series_position: "0",
      published_year: 1937,
      synced_at: Time.current
    )

    metadata_result = metadata_result(
      source_id: "OL_HOBBITW",
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      year: 1937
    )

    MetadataService.stub(:search, [ metadata_result ]) do
      get search_results_path, params: { q: "hobbit" }
    end

    assert_response :success
    assert_match "Related titles", response.body
    assert_match "Related titles in your library", response.body
    assert_match "Likely match", response.body
    assert_match "There and Back Again", response.body
    assert_match "Andy Serkis", response.body
  end

  test "results aggregates mocked hardcover google books and open library responses" do
    SettingsService.set(:metadata_source, "auto")
    SettingsService.set(:metadata_provider_priority, "hardcover,openlibrary,google_books")
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:hardcover_api_token, "test-token")
    SettingsService.set(:open_library_enabled, true)
    SettingsService.set(:google_books_enabled, true)
    HardcoverClient.reset_connection!
    GoogleBooksClient.reset_connection!
    OpenLibraryClient.reset_connection!

    query = "three provider book"

    VCR.turned_off do
      stub_hardcover_search([
        {
          "id" => 101,
          "title" => "Three Provider Book",
          "author_names" => [ "Ada Writer" ],
          "description" => "Hardcover description",
          "release_year" => 2024,
          "cached_image" => "https://images.example/hardcover.jpg",
          "has_audiobook" => true,
          "has_ebook" => false
        }
      ])
      stub_openlibrary_search(query, [
        {
          "key" => "/works/OL_THREE_W",
          "title" => "Three Provider Book",
          "author_name" => [ "Ada Writer" ],
          "first_publish_year" => 2024,
          "cover_i" => 12345,
          "edition_count" => 7
        }
      ])
      stub_google_books_search(query, [
        google_books_item("gb-three", "Three Provider Book", "Ada Writer", published_date: "2024-01-05")
      ])

      get search_results_path, params: { q: query }
    end

    assert_response :success
    assert_select "p", text: /1 result for/
    assert_select "h3", text: "Three Provider Book", count: 1
    assert_select "a", text: "Hardcover", count: 1
    assert_select "a", text: "Open Library", count: 1
    assert_select "a", text: "Google Books", count: 1
    assert_match "Powered by Google", response.body
  end

  test "stream_results accepts streaming search requests" do
    SettingsService.set(:metadata_source, "auto")
    SettingsService.set(:metadata_provider_priority, "hardcover,openlibrary,google_books")
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:hardcover_api_token, "test-token")
    SettingsService.set(:open_library_enabled, true)
    SettingsService.set(:google_books_enabled, true)
    HardcoverClient.reset_connection!
    GoogleBooksClient.reset_connection!
    OpenLibraryClient.reset_connection!

    query = "streamed provider book"

    VCR.turned_off do
      stub_hardcover_search([
        {
          "id" => 202,
          "title" => "Streamed Provider Book",
          "author_names" => [ "Ada Writer" ],
          "description" => "Hardcover description",
          "release_year" => 2025,
          "cached_image" => "https://images.example/streamed.jpg",
          "has_audiobook" => true,
          "has_ebook" => false
        }
      ])
      stub_openlibrary_search(query, [
        {
          "key" => "/works/OL_STREAMED_W",
          "title" => "Streamed Provider Book",
          "author_name" => [ "Ada Writer" ],
          "first_publish_year" => 2025,
          "cover_i" => 67890,
          "edition_count" => 3
        }
      ])
      stub_google_books_search(query, [
        google_books_item("gb-streamed", "Streamed Provider Book", "Ada Writer", published_date: "2025-02-03")
      ])

      get search_results_stream_path, params: { q: query }
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match %r{href="/search/details\?}, response.body
    assert_no_match %r{href="//search/details\?}, response.body
  end

  test "stream_results applies the normalized content filter to partial results" do
    aggregated_content_kinds = []
    stream_search = lambda do |_query, content_kind:, &block|
      assert_equal "graphic", content_kind
      block.call("openlibrary", [])
    end
    aggregate = lambda do |_results, content_kind:|
      aggregated_content_kinds << content_kind
      []
    end

    MetadataService.stub(:enabled_metadata_providers, [ "openlibrary" ]) do
      MetadataService.stub(:each_provider_search, stream_search) do
        MetadataService.stub(:aggregate_provider_results, aggregate) do
          get search_results_stream_path, params: { q: "akira", content_kind: "manga" }
        end
      end
    end

    assert_response :success
    assert_equal [ "graphic" ], aggregated_content_kinds
  end

  test "stream_results handles blank query" do
    get search_results_stream_path, params: { q: "" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
  end

  test "stream_results handles no enabled providers" do
    SettingsService.set(:metadata_source, "auto")
    SettingsService.set(:hardcover_enabled, false)
    SettingsService.set(:open_library_enabled, false)
    SettingsService.set(:google_books_enabled, false)

    get search_results_stream_path, params: { q: "fiction" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
  end

  test "stream_results handles provider thread failures" do
    SettingsService.set(:metadata_source, "openlibrary")
    SettingsService.set(:open_library_enabled, true)

    MetadataService.stub(:search_provider, ->(*) { raise StandardError, "provider boom" }) do
      get search_results_stream_path, params: { q: "fiction" }
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
  end

  test "results does not show related titles when no similar audiobookshelf item exists" do
    LibraryItem.destroy_all
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-1",
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      synced_at: Time.current
    )

    metadata_result = metadata_result(
      source_id: "OL_1984W",
      title: "1984",
      author: "George Orwell",
      year: 1949
    )

    MetadataService.stub(:search, [ metadata_result ]) do
      get search_results_path, params: { q: "1984" }
    end

    assert_response :success
    assert_no_match "Related titles in your library", response.body
  end

  test "results ignores missing audiobookshelf items" do
    LibraryItem.destroy_all
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-1",
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      missing: true,
      synced_at: Time.current
    )

    metadata_result = metadata_result(
      source_id: "OL_HOBBITW",
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      year: 1937
    )

    MetadataService.stub(:search, [ metadata_result ]) do
      get search_results_path, params: { q: "hobbit" }
    end

    assert_response :success
    assert_no_match "Related titles in your library", response.body
  end

  test "results renders one request action without passing formats in the URL" do
    candidate = MetadataSearch::Candidate.new(
      canonical_key: "google_books:gb-ebook-only",
      title: "Ebook Only",
      author: "Format Author",
      year: 2024,
      description: nil,
      cover_url: nil,
      series_name: nil,
      series_position: nil,
      has_ebook: true,
      has_audiobook: false,
      confidence: 70,
      editions: [],
      sources: [
        {
          source: "google_books",
          source_id: "gb-ebook-only",
          source_name: "Google Books",
          source_url: "https://books.google.com/books?id=gb-ebook-only",
          work_id: "google_books:gb-ebook-only"
        }
      ],
      available_book_types: [ "ebook" ]
    )

    MetadataService.stub(:search, [ candidate ]) do
      get search_results_path, params: { q: "ebook only" }
    end

    assert_response :success
    assert_select "a", text: "Request", count: 1
    assert_select "a", text: "Audiobook", count: 0
    assert_select "a", text: "Ebook", count: 0
    assert_no_match "available_book_types", response.body
  end

  test "result cards use provider identity for graphic labels and canonical links" do
    candidate = MetadataSearch::Candidate.new(
      canonical_key: "comic_vine:4000-card-source-policy",
      title: "Graphic Source Policy",
      author: "Creator",
      year: 2024,
      description: nil,
      cover_url: nil,
      series_name: nil,
      series_position: nil,
      has_ebook: false,
      has_audiobook: false,
      sources: [
        {
          source: "comic_vine",
          source_id: "4000-card-source-policy",
          source_name: "Comic Vine",
          source_url: nil,
          work_id: "comic_vine:4000-card-source-policy"
        }
      ],
      editions: [],
      confidence: 100,
      content_kind: "book"
    )

    MetadataService.stub(:search, [ candidate ]) do
      get search_results_path, params: { q: "source policy" }
    end

    assert_response :success
    assert_select "span", text: "Comics & Manga"
    assert_select "a[data-turbo-frame='modal'][href*='content_kind=graphic']", minimum: 2
    assert_select "a[href^='#{new_request_path}'][href*='content_kind=graphic']", text: "Request", count: 1
    assert_no_match "available_book_types", response.body
  end

  test "details renders modal with collection preview and collection request action" do
    preview_item = MetadataCollectionService::Item.new(
      work_id: "comic_vine:4000-101",
      source_work_ids: [ "comic_vine:4000-101" ],
      metadata_attrs: {
        title: "Saga - #1",
        cover_url: nil,
        issue_number: "1",
        release_date: "2012-03-14"
      }
    )

    ComicVineClient.stub(:configured?, false) do
      MetadataCollectionService.stub(:expand, [ preview_item ]) do
        get search_details_path, params: {
          modal: "1",
          work_id: "comic_vine:4050-99",
          title: "Saga",
          content_kind: "book",
          collection_source: "comic_vine",
          collection_id: "4050-99",
          collection_title: "Saga"
        }
      end
    end

    assert_response :success
    assert_select "turbo-frame#modal"
    assert_select "[data-controller='search-modal']"
    assert_select "a[href='#{search_modal_close_path}']", text: "Close"
    assert_select "span", text: "Comics & Manga"
    assert_select "dt", text: "First published"
    assert_select "h2", text: "Issues & Volumes"
    assert_match "Saga - #1", response.body
    assert_no_match "available_book_types", response.body
    assert_select "form[action='#{requests_path}']" do
      assert_select "input[name='collection_item_ids[]'][value='comic_vine:4000-101'][checked]"
      assert_select "input[name='request_scope'][value='collection']"
      assert_select "button[name='book_type'][value='comicbook']", text: "Request Selected (Comics & Manga)"
    end
  end

  test "details excludes items the user already has from the collection selection" do
    Book.create!(
      title: "Saga #1",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-101",
      file_path: "/comics/saga-1.cbz"
    )

    owned_item = MetadataCollectionService::Item.new(
      work_id: "comic_vine:4000-101",
      source_work_ids: [ "comic_vine:4000-101" ],
      metadata_attrs: { title: "Saga - #1", issue_number: "1" }
    )
    wanted_item = MetadataCollectionService::Item.new(
      work_id: "comic_vine:4000-102",
      source_work_ids: [ "comic_vine:4000-102" ],
      metadata_attrs: { title: "Saga - #2", issue_number: "2" }
    )

    ComicVineClient.stub(:configured?, false) do
      MetadataCollectionService.stub(:expand, [ owned_item, wanted_item ]) do
        get search_details_path, params: {
          modal: "1",
          work_id: "comic_vine:4050-99",
          title: "Saga",
          content_kind: "graphic",
          collection_source: "comic_vine",
          collection_id: "4050-99",
          collection_title: "Saga"
        }
      end
    end

    assert_response :success
    assert_select "input[name='collection_item_ids[]'][value='comic_vine:4000-101']", count: 0
    assert_select "input[name='collection_item_ids[]'][value='comic_vine:4000-102'][checked]"
    assert_select "span", text: "In library"
  end

  test "details enriches google books metadata and renders stable detail rows" do
    details = GoogleBooksClient::BookDetails.new(
      id: "gb-eclipse",
      title: "Eclipse",
      author: "Stephenie Meyer",
      description: "Bella must choose between friendship and love.",
      published_date: "2007-08-07",
      cover_url: nil,
      has_ebook: true,
      language: "en",
      page_count: 629,
      categories: [ "Young Adult Fiction" ],
      publisher: "Little, Brown"
    )

    GoogleBooksClient.stub(:configured?, true) do
      GoogleBooksClient.stub(:book, details) do
        get search_details_path, params: {
          modal: "1",
          work_id: "google_books:gb-eclipse",
          title: "Eclipse"
        }
      end
    end

    assert_response :success
    assert_select "turbo-frame#modal"
    assert_select "h2", text: "Metadata"
    assert_select "dt", text: "Publisher"
    assert_select "dd", text: "Little, Brown"
    assert_select "dt", text: "Pages"
    assert_select "dd", text: "629"
    assert_select "dt", text: "Genres"
    assert_select "dd", text: "Young Adult Fiction"
    assert_select "a[href='https://books.google.com/books?id=gb-eclipse']", text: "Google Books"
    assert_match "Bella must choose between friendship and love.", response.body
  end

  test "details does not forward descriptions to the request URL" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    GoogleBooksClient.stub(:configured?, false) do
      get search_details_path, params: {
        modal: "1",
        work_id: "google_books:gb-long-description",
        title: "Long title " * 1_000,
        author: "Long author " * 1_000,
        cover_url: "https://example.com/#{'long-cover-' * 1_000}",
        description: "Long description " * 1_000,
        series: "Long series " * 1_000,
        collection_title: "Long collection " * 1_000
      }

      assert_response :redirect
      assert_compact_metadata_url response.location
      follow_redirect!
      assert_response :success
      assert_select "a[href^='#{new_request_path}']", text: "Request" do |links|
        assert_compact_metadata_url links.first["href"]
      end
    end
  ensure
    Rails.cache = original_cache
  end

  test "close_modal returns an empty modal frame" do
    get search_modal_close_path

    assert_response :success
    assert_select "turbo-frame#modal"
    assert_no_match "Close", response.body
  end

  private

  def assert_compact_metadata_url(href)
    decoded_href = CGI.unescapeHTML(href)
    query = Rack::Utils.parse_nested_query(URI.parse(decoded_href).query)
    allowed_keys = %w[
      metadata_token work_id source_work_ids content_kind request_scope
      collection_source collection_id modal
    ]

    assert_empty query.keys - allowed_keys
    assert_operator decoded_href.bytesize, :<, 1.kilobyte
  end

  def metadata_result(source_id:, title:, author:, year:)
    MetadataService::SearchResult.new(
      source: "openlibrary",
      source_id: source_id,
      title: title,
      author: author,
      description: nil,
      year: year,
      cover_url: nil,
      has_audiobook: nil,
      has_ebook: nil,
      series_name: nil,
      series_position: nil
    )
  end

  def stub_hardcover_search(results)
    typesense_response = {
      "facet_counts" => [],
      "found" => results.size,
      "hits" => results.map { |result| { "document" => result } },
      "request_params" => {},
      "search_cutoff" => false,
      "search_time_ms" => 5
    }

    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { "data" => { "search" => { "results" => typesense_response } } }.to_json
      )
  end

  def stub_openlibrary_search(query, docs)
    stub_request(:get, "#{OpenLibraryClient::BASE_URL}/search.json")
      .with(query: hash_including("q" => query))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { "docs" => docs }.to_json
      )
  end

  def google_books_item(id, title, author, published_date:)
    {
      "id" => id,
      "volumeInfo" => {
        "title" => title,
        "authors" => [ author ],
        "description" => "Google Books description",
        "publishedDate" => published_date,
        "imageLinks" => { "thumbnail" => "https://books.google.example/cover.jpg" },
        "canonicalVolumeLink" => "https://books.google.com/books?id=#{id}"
      },
      "saleInfo" => { "isEbook" => true }
    }
  end

  def stub_google_books_search(query, items)
    stub_request(:get, "#{GoogleBooksClient::BASE_URL}/books/v1/volumes")
      .with(query: hash_including("q" => query))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { "items" => items }.to_json
      )
  end
end
