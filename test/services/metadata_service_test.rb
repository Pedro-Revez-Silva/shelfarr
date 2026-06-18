# frozen_string_literal: true

require "test_helper"

class MetadataServiceTest < ActiveSupport::TestCase
  setup do
    @original_source = SettingsService.get(:metadata_source)
    @original_token = SettingsService.get(:hardcover_api_token)
    @original_hardcover_search_limit = SettingsService.get(:hardcover_search_limit)
    @original_open_library_search_limit = SettingsService.get(:open_library_search_limit)
    @original_google_books_search_limit = SettingsService.get(:google_books_search_limit)
    HardcoverClient.reset_connection!
    GoogleBooksClient.reset_connection!
  end

  teardown do
    SettingsService.set(:metadata_source, @original_source || "auto")
    SettingsService.set(:hardcover_api_token, @original_token || "")
    SettingsService.set(:hardcover_search_limit, @original_hardcover_search_limit || 10)
    SettingsService.set(:open_library_search_limit, @original_open_library_search_limit || 20)
    SettingsService.set(:google_books_search_limit, @original_google_books_search_limit || 20)
    HardcoverClient.reset_connection!
    GoogleBooksClient.reset_connection!
  end

  test "search uses openlibrary when source is openlibrary" do
    SettingsService.set(:metadata_source, "openlibrary")

    with_cassette("open_library/search_harry_potter") do
      results = MetadataService.search("harry potter")

      assert results.any?
      assert_equal "openlibrary", results.first.source
    end
  end

  test "search uses hardcover when source is hardcover and configured" do
    SettingsService.set(:metadata_source, "hardcover")
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_search([
        { "id" => 456, "title" => "Harry Potter", "author_names" => [ "J.K. Rowling" ],
          "release_year" => 1997, "cached_image" => nil, "has_audiobook" => true, "has_ebook" => true }
      ])

      results = MetadataService.search("harry potter")

      assert results.any?
      assert_equal "hardcover", results.first.source
    end
  end

  test "search uses google books when source is google_books" do
    SettingsService.set(:metadata_source, "google_books")

    VCR.turned_off do
      stub_google_books_search([
        google_books_item("abc123", "Harry Potter", "J.K. Rowling")
      ])

      results = MetadataService.search("harry potter")

      assert results.any?
      assert_equal "google_books", results.first.source
      assert_equal "abc123", results.first.source_id
      assert_equal 1997, results.first.year
    end
  end

  test "search uses configured hardcover limit when no limit is provided" do
    SettingsService.set(:metadata_source, "hardcover")
    SettingsService.set(:hardcover_api_token, "test_token")
    SettingsService.set(:hardcover_search_limit, 37)

    VCR.turned_off do
      stub_hardcover_search([
        { "id" => 456, "title" => "Harry Potter", "author_names" => [ "J.K. Rowling" ],
          "release_year" => 1997, "cached_image" => nil, "has_audiobook" => true, "has_ebook" => true }
      ], expected_per_page: 37)

      results = MetadataService.search("harry potter")

      assert_equal "hardcover", results.first.source
    end
  end

  test "search uses configured openlibrary limit when no limit is provided" do
    SettingsService.set(:metadata_source, "openlibrary")
    SettingsService.set(:open_library_search_limit, 43)

    VCR.turned_off do
      stub_request(:get, "#{OpenLibraryClient::BASE_URL}/search.json")
        .with(query: hash_including("q" => "harry potter", "limit" => "43"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "docs" => [
              {
                "key" => "/works/OL82563W",
                "title" => "Harry Potter",
                "author_name" => [ "J.K. Rowling" ],
                "first_publish_year" => 1997
              }
            ]
          }.to_json
        )

      results = MetadataService.search("harry potter")

      assert_equal "openlibrary", results.first.source
    end
  end

  test "search uses configured google books limit when no limit is provided" do
    SettingsService.set(:metadata_source, "google_books")
    SettingsService.set(:google_books_search_limit, 17)

    VCR.turned_off do
      stub_google_books_search([
        google_books_item("abc123", "Harry Potter", "J.K. Rowling")
      ], expected_max_results: 17)

      results = MetadataService.search("harry potter")

      assert_equal "google_books", results.first.source
    end
  end

  test "search falls back to openlibrary when hardcover returns no results in auto mode" do
    SettingsService.set(:metadata_source, "auto")
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_search([])
    end

    with_cassette("open_library/search_harry_potter") do
      results = MetadataService.search("harry potter")

      assert results.any?
      assert_equal "openlibrary", results.first.source
    end
  end

  test "search falls back to google books when openlibrary returns no results in auto mode" do
    SettingsService.set(:metadata_source, "auto")
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_search([])
      stub_openlibrary_search([])
      stub_google_books_search([
        google_books_item("abc123", "Harry Potter", "J.K. Rowling")
      ])
      results = MetadataService.search("harry potter")

      assert results.any?
      assert_equal "google_books", results.first.source
    end
  end

  test "search uses openlibrary when hardcover not configured in auto mode" do
    SettingsService.set(:metadata_source, "auto")
    SettingsService.set(:hardcover_api_token, "")

    with_cassette("open_library/search_harry_potter") do
      results = MetadataService.search("harry potter")

      assert results.any?
      assert_equal "openlibrary", results.first.source
    end
  end

  test "book_details handles hardcover work_id" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_book({
        "id" => 12345,
        "title" => "Test Book",
        "description" => "Description",
        "release_year" => 2020,
        "cached_image" => "https://example.com/cover.jpg",
        "contributions" => [ { "author" => { "name" => "Test Author" } } ],
        "default_physical_edition" => nil,
        "book_series" => []
      })

      result = MetadataService.book_details("hardcover:12345")

      assert_equal "hardcover", result.source
      assert_equal "Test Book", result.title
      assert_nil result.series_position
    end
  end

  test "book_details handles openlibrary work_id" do
    with_cassette("open_library/work_details") do
      result = MetadataService.book_details("openlibrary:OL45804W")

      assert_equal "openlibrary", result.source
      assert result.title.present?
    end
  end

  test "book_details handles google books work_id" do
    VCR.turned_off do
      stub_google_books_book("abc123", google_books_item("abc123", "Test Book", "Test Author"))

      result = MetadataService.book_details("google_books:abc123")

      assert_equal "google_books", result.source
      assert_equal "Test Book", result.title
      assert_equal "Test Author", result.author
    end
  end

  test "book_details handles legacy work_id without prefix" do
    with_cassette("open_library/work_details") do
      result = MetadataService.book_details("OL45804W")

      assert_equal "openlibrary", result.source
    end
  end

  test "SearchResult has unified interface" do
    result = MetadataService::SearchResult.new(
      source: "hardcover",
      source_id: "123",
      title: "Test Book",
      author: "Test Author",
      description: "Description",
      year: 2020,
      cover_url: "https://example.com/cover.jpg",
      has_audiobook: true,
      has_ebook: true,
      series_name: "Test Series",
      series_position: "1"
    )

    assert_equal "hardcover:123", result.work_id
    assert_equal 2020, result.first_publish_year
    assert_nil result.cover_id
    assert_equal "1", result.series_position
    assert_equal "Hardcover", result.source_name
    assert_equal "https://hardcover.app/books/123", result.source_url
    assert_equal "Metadata from Hardcover", result.source_attribution
  end

  test "SearchResult exposes source metadata for each provider" do
    open_library = MetadataService::SearchResult.new(
      source: "openlibrary",
      source_id: "OL123W",
      title: "Open Book",
      author: nil,
      description: nil,
      year: nil,
      cover_url: nil,
      has_audiobook: nil,
      has_ebook: nil,
      series_name: nil,
      series_position: nil
    )
    google_books = MetadataService::SearchResult.new(
      source: "google_books",
      source_id: "abc123",
      title: "Google Book",
      author: nil,
      description: nil,
      year: nil,
      cover_url: nil,
      has_audiobook: nil,
      has_ebook: nil,
      series_name: nil,
      series_position: nil
    )

    assert_equal "Open Library", open_library.source_name
    assert_equal "https://openlibrary.org/works/OL123W", open_library.source_url
    assert_equal "Google Books", google_books.source_name
    assert_equal "https://books.google.com/books?id=abc123", google_books.source_url
    assert google_books.google_books?
  end

  test "metadata_source returns configured value" do
    SettingsService.set(:metadata_source, "hardcover")
    assert_equal "hardcover", MetadataService.metadata_source

    SettingsService.set(:metadata_source, "openlibrary")
    assert_equal "openlibrary", MetadataService.metadata_source

    SettingsService.set(:metadata_source, "google_books")
    assert_equal "google_books", MetadataService.metadata_source

    SettingsService.set(:metadata_source, "auto")
    assert_equal "auto", MetadataService.metadata_source
  end

  test "available? returns true when openlibrary source" do
    SettingsService.set(:metadata_source, "openlibrary")
    assert MetadataService.available?
  end

  test "available? returns true when google books source" do
    SettingsService.set(:metadata_source, "google_books")
    assert MetadataService.available?
  end

  test "available? returns true when auto source" do
    SettingsService.set(:metadata_source, "auto")
    assert MetadataService.available?
  end

  test "available? returns true when hardcover configured" do
    SettingsService.set(:metadata_source, "hardcover")
    SettingsService.set(:hardcover_api_token, "test_token")
    assert MetadataService.available?
  end

  test "available? returns false when hardcover not configured" do
    SettingsService.set(:metadata_source, "hardcover")
    SettingsService.set(:hardcover_api_token, "")
    assert_not MetadataService.available?
  end

  private

  def stub_hardcover_search(results, expected_per_page: nil)
    typesense_response = {
      "facet_counts" => [],
      "found" => results.size,
      "hits" => results.map { |r| { "document" => r } },
      "request_params" => {},
      "search_cutoff" => false,
      "search_time_ms" => 5
    }

    stub = stub_request(:post, HardcoverClient::BASE_URL)
    if expected_per_page
      stub = stub.with do |request|
        JSON.parse(request.body).dig("variables", "perPage") == expected_per_page
      end
    end

    stub.to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { "data" => { "search" => { "results" => typesense_response } } }.to_json
    )
  end

  def stub_hardcover_book(book_data)
    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { "data" => { "books" => [ book_data ] } }.to_json
      )
  end

  def stub_openlibrary_search(docs)
    stub_request(:get, "#{OpenLibraryClient::BASE_URL}/search.json")
      .with(query: hash_including("q" => "harry potter"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { "docs" => docs }.to_json
      )
  end

  def google_books_item(id, title, author)
    {
      "id" => id,
      "volumeInfo" => {
        "title" => title,
        "authors" => [ author ],
        "description" => "Description",
        "publishedDate" => "1997-06-26",
        "imageLinks" => { "thumbnail" => "https://books.google.com/cover.jpg" }
      },
      "saleInfo" => { "isEbook" => true }
    }
  end

  def stub_google_books_search(items, expected_max_results: nil)
    stub = stub_request(:get, "#{GoogleBooksClient::BASE_URL}/books/v1/volumes")
      .with(query: hash_including("q" => "harry potter"))

    if expected_max_results
      stub = stub.with(query: hash_including("q" => "harry potter", "maxResults" => expected_max_results.to_s))
    end

    stub.to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { "items" => items }.to_json
    )
  end

  def stub_google_books_book(id, item)
    stub_request(:get, "#{GoogleBooksClient::BASE_URL}/books/v1/volumes/#{id}")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: item.to_json
      )
  end
end
