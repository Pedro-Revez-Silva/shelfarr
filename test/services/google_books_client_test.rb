# frozen_string_literal: true

require "test_helper"

class GoogleBooksClientTest < ActiveSupport::TestCase
  def search_body(items)
    { "kind" => "books#volumes", "totalItems" => items.size, "items" => items }.to_json
  end

  test "search returns array of SearchResult" do
    VCR.turned_off do
      stub_request(:get, "#{GoogleBooksClient::BASE_URL}/volumes")
        .with(query: hash_including("q" => "harry potter"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: search_body([
            {
              "id" => "vol123",
              "volumeInfo" => {
                "title" => "Harry Potter",
                "authors" => [ "J.K. Rowling" ],
                "description" => "A boy wizard.",
                "publishedDate" => "1997-06-26",
                "imageLinks" => { "thumbnail" => "http://books.google.com/cover.jpg&edge=curl" }
              },
              "accessInfo" => { "epub" => { "isAvailable" => true } }
            }
          ])
        )

      results = GoogleBooksClient.search("harry potter")

      assert_kind_of Array, results
      assert_kind_of GoogleBooksClient::SearchResult, results.first

      result = results.first
      assert_equal "vol123", result.id
      assert_equal "googlebooks:vol123", result.work_id
      assert_equal "Harry Potter", result.title
      assert_equal "J.K. Rowling", result.author
      assert_equal 1997, result.year
      assert_equal true, result.has_ebook
      assert_equal "https://books.google.com/cover.jpg", result.cover_url
    end
  end

  test "search returns empty array when no items" do
    VCR.turned_off do
      stub_request(:get, "#{GoogleBooksClient::BASE_URL}/volumes")
        .with(query: hash_including("q" => "zzzznomatch"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "kind" => "books#volumes", "totalItems" => 0 }.to_json
        )

      assert_equal [], GoogleBooksClient.search("zzzznomatch")
    end
  end

  test "search respects limit and includes api key when configured" do
    original_key = SettingsService.get(:google_books_api_key)
    SettingsService.set(:google_books_api_key, "secret-key")

    VCR.turned_off do
      stub = stub_request(:get, "#{GoogleBooksClient::BASE_URL}/volumes")
        .with(query: hash_including("maxResults" => "5", "key" => "secret-key"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "totalItems" => 0 }.to_json
        )

      GoogleBooksClient.search("fiction", limit: 5)
      assert_requested(stub)
    end
  ensure
    SettingsService.set(:google_books_api_key, original_key || "")
  end

  test "volume returns VolumeDetails" do
    VCR.turned_off do
      stub_request(:get, "#{GoogleBooksClient::BASE_URL}/volumes/vol123")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "id" => "vol123",
            "volumeInfo" => {
              "title" => "Harry Potter",
              "authors" => [ "J.K. Rowling" ],
              "description" => "A boy wizard.",
              "publishedDate" => "1997",
              "pageCount" => 223,
              "imageLinks" => { "thumbnail" => "https://books.google.com/cover.jpg" }
            },
            "accessInfo" => { "epub" => { "isAvailable" => false } }
          }.to_json
        )

      volume = GoogleBooksClient.volume("vol123")

      assert_kind_of GoogleBooksClient::VolumeDetails, volume
      assert_equal "vol123", volume.id
      assert_equal "googlebooks:vol123", volume.work_id
      assert_equal "Harry Potter", volume.title
      assert_equal 223, volume.pages
      assert_equal false, volume.has_ebook
    end
  end

  test "volume raises NotFoundError for 404" do
    VCR.turned_off do
      stub_request(:get, "#{GoogleBooksClient::BASE_URL}/volumes/missing")
        .to_return(status: 404, body: "{}")

      assert_raises GoogleBooksClient::NotFoundError do
        GoogleBooksClient.volume("missing")
      end
    end
  end

  test "search raises RateLimitError for 429" do
    VCR.turned_off do
      stub_request(:get, "#{GoogleBooksClient::BASE_URL}/volumes")
        .with(query: hash_including("q" => "anything"))
        .to_return(status: 429, body: "{}")

      assert_raises GoogleBooksClient::RateLimitError do
        GoogleBooksClient.search("anything")
      end
    end
  end

  test "test_connection returns true on success" do
    original_key = SettingsService.get(:google_books_api_key)
    SettingsService.set(:google_books_api_key, "secret-key")

    VCR.turned_off do
      stub_request(:get, "#{GoogleBooksClient::BASE_URL}/volumes")
        .with(query: hash_including("q" => "ruby"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "totalItems" => 1, "items" => [] }.to_json
        )

      assert_equal true, GoogleBooksClient.test_connection
    end
  ensure
    SettingsService.set(:google_books_api_key, original_key || "")
  end

  test "test_connection returns false on error" do
    original_key = SettingsService.get(:google_books_api_key)
    SettingsService.set(:google_books_api_key, "secret-key")

    VCR.turned_off do
      stub_request(:get, "#{GoogleBooksClient::BASE_URL}/volumes")
        .with(query: hash_including("q" => "ruby"))
        .to_return(status: 500, body: "{}")

      assert_equal false, GoogleBooksClient.test_connection
    end
  ensure
    SettingsService.set(:google_books_api_key, original_key || "")
  end

  test "test_connection returns false when not configured" do
    original_key = SettingsService.get(:google_books_api_key)
    SettingsService.set(:google_books_api_key, "")

    assert_equal false, GoogleBooksClient.test_connection
  ensure
    SettingsService.set(:google_books_api_key, original_key || "")
  end

  test "configured? requires an api key" do
    original_key = SettingsService.get(:google_books_api_key)

    SettingsService.set(:google_books_api_key, "")
    assert_not GoogleBooksClient.configured?

    SettingsService.set(:google_books_api_key, "secret-key")
    assert GoogleBooksClient.configured?
  ensure
    SettingsService.set(:google_books_api_key, original_key || "")
  end
end
