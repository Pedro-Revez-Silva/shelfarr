# frozen_string_literal: true

require "test_helper"

class API::V1::SearchControllerTest < ActionDispatch::IntegrationTest
  setup do
    SettingsService.set(:api_token, "apitoken")
  end

  test "returns metadata search results" do
    result = MetadataService::SearchResult.new(
      source: "openlibrary",
      source_id: "OL_API_SEARCH_123W",
      title: "API Search Book",
      author: "Search Author",
      description: nil,
      year: 2024,
      cover_url: nil,
      has_audiobook: nil,
      has_ebook: nil,
      series_name: nil,
      series_position: nil
    )

    MetadataService.stub(:search, [ result ]) do
      get api_v1_search_path,
        headers: { "Authorization" => "Bearer apitoken" },
        params: { q: "api search" }
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "openlibrary:OL_API_SEARCH_123W", body.dig("results", 0, "work_id")
    assert_equal "API Search Book", body.dig("results", 0, "title")
    assert_equal "Open Library", body.dig("results", 0, "source_name")
    assert_equal "https://openlibrary.org/works/OL_API_SEARCH_123W", body.dig("results", 0, "source_url")
  end

  test "returns aggregated candidate fields" do
    candidate = MetadataSearch::Candidate.new(
      canonical_key: "isbn:9780547928227",
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      year: 1937,
      description: nil,
      cover_url: nil,
      series_name: nil,
      series_position: nil,
      has_ebook: true,
      has_audiobook: nil,
      confidence: 100,
      editions: [ { source: "google_books", source_id: "gb123", isbn_13: "9780547928227" } ],
      sources: [
        { source: "openlibrary", source_id: "OL123W", source_name: "Open Library", source_url: "https://openlibrary.org/works/OL123W", work_id: "openlibrary:OL123W" },
        { source: "google_books", source_id: "gb123", source_name: "Google Books", source_url: "https://books.google.com/books?id=gb123", work_id: "google_books:gb123" }
      ]
    )

    MetadataService.stub(:search, [ candidate ]) do
      get api_v1_search_path,
        headers: { "Authorization" => "Bearer apitoken" },
        params: { q: "hobbit" }
    end

    assert_response :success
    body = JSON.parse(response.body)
    payload = body.fetch("results").first
    assert_equal "isbn:9780547928227", payload["canonical_key"]
    assert_equal "openlibrary:OL123W", payload["work_id"]
    assert_equal "openlibrary", payload["source"]
    assert_equal [ "openlibrary", "google_books" ], payload.fetch("sources").map { |source| source["source"] }
    assert_equal 1, payload.fetch("editions").size
    assert_equal 100, payload["confidence"]
  end

  test "requires a query" do
    get api_v1_search_path,
      headers: { "Authorization" => "Bearer apitoken" }

    assert_response :unprocessable_entity
  end
end
