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

  test "requires a query" do
    get api_v1_search_path,
      headers: { "Authorization" => "Bearer apitoken" }

    assert_response :unprocessable_entity
  end
end
