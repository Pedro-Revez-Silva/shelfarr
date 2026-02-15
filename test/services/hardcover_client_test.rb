# frozen_string_literal: true

require "test_helper"

class HardcoverClientTest < ActiveSupport::TestCase
  setup do
    @original_token = SettingsService.get(:hardcover_api_token)
    HardcoverClient.reset_connection!
  end

  teardown do
    SettingsService.set(:hardcover_api_token, @original_token || "")
    HardcoverClient.reset_connection!
  end

  test "configured? returns false without token" do
    SettingsService.set(:hardcover_api_token, "")
    assert_not HardcoverClient.configured?
  end

  test "configured? returns true with token" do
    SettingsService.set(:hardcover_api_token, "test_token")
    assert HardcoverClient.configured?
  end

  test "search raises NotConfiguredError without token" do
    SettingsService.set(:hardcover_api_token, "")

    assert_raises HardcoverClient::NotConfiguredError do
      HardcoverClient.search("test")
    end
  end

  test "search returns array of SearchResult" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_search("lord of the rings", [
        { "id" => 123, "title" => "The Lord of the Rings", "author_names" => [ "J.R.R. Tolkien" ],
          "release_year" => 1954, "cached_image" => "https://example.com/cover.jpg",
          "has_audiobook" => true, "has_ebook" => true }
      ])

      results = HardcoverClient.search("lord of the rings")

      assert_kind_of Array, results
      assert_equal 1, results.size
      assert_kind_of HardcoverClient::SearchResult, results.first

      result = results.first
      assert_equal "The Lord of the Rings", result.title
      assert_equal "J.R.R. Tolkien", result.author
      assert_equal 1954, result.release_year
      assert result.has_audiobook
      assert result.has_ebook
    end
  end

  test "search handles empty results" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_search("asdfghjklqwertyuiop", [])

      results = HardcoverClient.search("asdfghjklqwertyuiop")
      assert_equal [], results
    end
  end

  test "search returns empty array when results shape is invalid" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_request(:post, HardcoverClient::BASE_URL)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "data" => { "search" => { "results" => [] } } }.to_json
        )

      results = HardcoverClient.search("lord of the rings")

      assert_equal [], results
    end
  end

  test "search extracts cover_url from image hash" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_search("dune", [
        {
          "id" => 123,
          "title" => "Dune",
          "author_names" => [ "Frank Herbert" ],
          "release_year" => 1965,
          "cached_image" => nil,
          "image" => { "url" => "https://example.com/image-cover.jpg" },
          "has_audiobook" => true,
          "has_ebook" => true
        }
      ])

      results = HardcoverClient.search("dune")

      assert_equal 1, results.size
      assert_equal "https://example.com/image-cover.jpg", results.first.cover_url
    end
  end

  test "book returns BookDetails" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_book(12345, {
        "id" => 12345,
        "title" => "Test Book",
        "description" => "A test description",
        "release_year" => 2020,
        "cached_image" => "https://example.com/cover.jpg",
        "contributions" => [ { "author" => { "name" => "Test Author" } } ],
        "default_physical_edition" => { "pages" => 300 },
        "book_series" => [ { "series" => { "name" => "Test Series" } } ]
      })

      book = HardcoverClient.book(12345)

      assert_kind_of HardcoverClient::BookDetails, book
      assert_equal "Test Book", book.title
      assert_equal "Test Author", book.author
      assert_equal 2020, book.release_year
      assert_equal 300, book.pages
      assert_equal "Test Series", book.series_name
    end
  end

  test "book extracts cover_url from cached_image hash" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_book(12346, {
        "id" => 12346,
        "title" => "Hash Cover Book",
        "description" => "A test description",
        "release_year" => 2021,
        "cached_image" => { "url" => "https://example.com/hash-cover.jpg" },
        "contributions" => [ { "author" => { "name" => "Test Author" } } ],
        "default_physical_edition" => { "pages" => 320 },
        "book_series" => []
      })

      book = HardcoverClient.book(12346)

      assert_equal "https://example.com/hash-cover.jpg", book.cover_url
    end
  end

  test "book raises NotFoundError for invalid id" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_hardcover_book(999999999, nil)

      assert_raises HardcoverClient::NotFoundError do
        HardcoverClient.book(999999999)
      end
    end
  end

  test "handles authentication error" do
    SettingsService.set(:hardcover_api_token, "invalid_token")

    VCR.turned_off do
      stub_request(:post, HardcoverClient::BASE_URL)
        .to_return(status: 401, body: '{"error": "Unauthorized"}')

      assert_raises HardcoverClient::AuthenticationError do
        HardcoverClient.search("test")
      end
    end
  end

  test "handles rate limit error" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_request(:post, HardcoverClient::BASE_URL)
        .to_return(status: 429, body: '{"error": "Rate limit exceeded"}')

      assert_raises HardcoverClient::RateLimitError do
        HardcoverClient.search("test")
      end
    end
  end

  test "test_connection returns true on success" do
    SettingsService.set(:hardcover_api_token, "test_token")

    VCR.turned_off do
      stub_request(:post, HardcoverClient::BASE_URL)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "data" => { "me" => { "id" => 123 } } }.to_json
        )

      assert HardcoverClient.test_connection
    end
  end

  test "test_connection returns false on auth failure" do
    SettingsService.set(:hardcover_api_token, "invalid_token")

    VCR.turned_off do
      stub_request(:post, HardcoverClient::BASE_URL)
        .to_return(status: 401, body: '{"error": "Unauthorized"}')

      assert_not HardcoverClient.test_connection
    end
  end

  test "work_id includes source prefix" do
    result = HardcoverClient::SearchResult.new(
      id: "12345",
      title: "Test",
      author: "Author",
      description: nil,
      release_year: 2020,
      cover_url: nil,
      has_audiobook: true,
      has_ebook: true
    )

    assert_equal "hardcover:12345", result.work_id
  end

  private

  def stub_hardcover_search(query, results)
    typesense_response = {
      "facet_counts" => [],
      "found" => results.size,
      "hits" => results.map { |r| { "document" => r } },
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

  def stub_hardcover_book(id, book_data)
    books = book_data ? [ book_data ] : []
    stub_request(:post, HardcoverClient::BASE_URL)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { "data" => { "books" => books } }.to_json
      )
  end
end
