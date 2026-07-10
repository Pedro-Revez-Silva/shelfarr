# frozen_string_literal: true

require "test_helper"

class GoogleBooksClientTest < ActiveSupport::TestCase
  setup do
    @original_api_key = SettingsService.get(:google_books_api_key)
    @original_limit = SettingsService.get(:google_books_search_limit)
    GoogleBooksClient.reset_connection!
  end

  teardown do
    SettingsService.set(:google_books_api_key, @original_api_key || "")
    SettingsService.set(:google_books_search_limit, @original_limit || 20)
    GoogleBooksClient.reset_connection!
  end

  test "search returns array of SearchResult" do
    VCR.turned_off do
      stub_google_books_search("harry potter", [ google_books_item ])

      results = GoogleBooksClient.search("harry potter")

      assert_kind_of Array, results
      assert_equal 1, results.size
      assert_kind_of GoogleBooksClient::SearchResult, results.first

      result = results.first
      assert_equal "abc123", result.id
      assert_equal "Harry Potter and the Philosopher's Stone", result.title
      assert_equal "J.K. Rowling", result.author
      assert_equal 1997, result.first_publish_year
      assert_equal "https://books.google.com/cover.jpg", result.cover_url
      assert result.has_ebook
      assert_equal [ "Fantasy" ], result.categories
    end
  end

  test "search returns empty array for no results" do
    VCR.turned_off do
      stub_google_books_search("asdfghjklqwertyuiop", [])

      assert_equal [], GoogleBooksClient.search("asdfghjklqwertyuiop")
    end
  end

  test "search respects configured limit" do
    SettingsService.set(:google_books_search_limit, 13)

    VCR.turned_off do
      stub_google_books_search("fiction", [], expected_max_results: 13)

      assert_equal [], GoogleBooksClient.search("fiction")
    end
  end

  test "search includes api key when configured" do
    SettingsService.set(:google_books_api_key, "secret-key")

    VCR.turned_off do
      stub_google_books_search("fiction", [], expected_key: "secret-key")

      assert_equal [], GoogleBooksClient.search("fiction")
    end
  end

  test "search omits api key when not configured" do
    SettingsService.set(:google_books_api_key, "")

    VCR.turned_off do
      stub = stub_request(:get, "#{GoogleBooksClient::BASE_URL}/books/v1/volumes")
        .with(query: hash_including("q" => "fiction"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "items" => [] }.to_json
        )

      assert_equal [], GoogleBooksClient.search("fiction")
      assert_requested(:get, %r{#{Regexp.escape(GoogleBooksClient::BASE_URL)}/books/v1/volumes}) do |request|
        Rack::Utils.parse_query(URI(request.uri).query).exclude?("key")
      end
    end
  end

  test "search clamps limit to Google Books maximum" do
    VCR.turned_off do
      stub_google_books_search("fiction", [], expected_max_results: 40)

      assert_equal [], GoogleBooksClient.search("fiction", limit: 99)
    end
  end

  test "book returns BookDetails" do
    VCR.turned_off do
      stub_google_books_book("abc123", google_books_item)

      book = GoogleBooksClient.book("abc123")

      assert_kind_of GoogleBooksClient::BookDetails, book
      assert_equal "abc123", book.id
      assert_equal "Harry Potter and the Philosopher's Stone", book.title
      assert_equal 1997, book.release_year
      assert_equal [ "Fantasy" ], book.categories
    end
  end

  test "book includes api key when configured" do
    SettingsService.set(:google_books_api_key, "secret-key")

    VCR.turned_off do
      stub_google_books_book("abc123", google_books_item, expected_key: "secret-key")

      assert_equal "abc123", GoogleBooksClient.book("abc123").id
    end
  end

  test "book raises NotFoundError when volumeInfo title is missing" do
    VCR.turned_off do
      stub_google_books_book("abc123", { "id" => "abc123" })

      assert_raises GoogleBooksClient::NotFoundError do
        GoogleBooksClient.book("abc123")
      end
    end
  end

  test "search raises AuthenticationError for invalid api key" do
    VCR.turned_off do
      stub_request(:get, "#{GoogleBooksClient::BASE_URL}/books/v1/volumes")
        .with(query: hash_including("q" => "fiction"))
        .to_return(
          status: 403,
          headers: { "Content-Type" => "application/json" },
          body: { "error" => { "message" => "API key not valid. Please pass a valid API key." } }.to_json
        )

      assert_raises GoogleBooksClient::AuthenticationError do
        GoogleBooksClient.search("fiction")
      end
    end
  end

  test "search raises RateLimitError for quota exceeded 403" do
    VCR.turned_off do
      stub_request(:get, "#{GoogleBooksClient::BASE_URL}/books/v1/volumes")
        .with(query: hash_including("q" => "fiction"))
        .to_return(
          status: 403,
          headers: { "Content-Type" => "application/json" },
          body: { "error" => { "message" => "Daily Limit Exceeded" } }.to_json
        )

      assert_raises GoogleBooksClient::RateLimitError do
        GoogleBooksClient.search("fiction")
      end
    end
  end

  test "book raises NotFoundError for invalid id" do
    VCR.turned_off do
      stub_request(:get, "#{GoogleBooksClient::BASE_URL}/books/v1/volumes/missing")
        .to_return(status: 404, body: { "error" => "Not found" }.to_json)

      assert_raises GoogleBooksClient::NotFoundError do
        GoogleBooksClient.book("missing")
      end
    end
  end

  test "work_id includes source prefix" do
    result = GoogleBooksClient::SearchResult.new(
      id: "abc123",
      title: "Test",
      author: "Author",
      description: nil,
      published_date: "2020",
      cover_url: nil,
      has_ebook: false,
      language: "en"
    )

    assert_equal "google_books:abc123", result.work_id
  end

  private

  def google_books_item
    {
      "id" => "abc123",
      "volumeInfo" => {
        "title" => "Harry Potter and the Philosopher's Stone",
        "authors" => [ "J.K. Rowling" ],
        "description" => "A wizarding school story",
        "publishedDate" => "1997-06-26",
        "imageLinks" => { "thumbnail" => "http://books.google.com/cover.jpg" },
        "language" => "en",
        "pageCount" => 223,
        "categories" => [ "Fantasy" ]
      },
      "saleInfo" => { "isEbook" => true },
      "accessInfo" => { "epub" => { "isAvailable" => true } }
    }
  end

  def stub_google_books_search(query, items, expected_max_results: nil, expected_key: nil)
    stub = stub_request(:get, "#{GoogleBooksClient::BASE_URL}/books/v1/volumes")
      .with(query: hash_including("q" => query))

    if expected_max_results
      stub = stub.with(query: hash_including("q" => query, "maxResults" => expected_max_results.to_s))
    end

    if expected_key
      stub = stub.with(query: hash_including("q" => query, "key" => expected_key))
    end

    stub.to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { "items" => items }.to_json
    )
  end

  def stub_google_books_book(id, item, expected_key: nil)
    stub = stub_request(:get, "#{GoogleBooksClient::BASE_URL}/books/v1/volumes/#{id}")
    stub = stub.with(query: hash_including("key" => expected_key)) if expected_key

    stub
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: item.to_json
      )
  end
end
