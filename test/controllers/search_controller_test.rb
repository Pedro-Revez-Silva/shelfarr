# frozen_string_literal: true

require "test_helper"

class SearchControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
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
  end

  test "results returns search results" do
    GoogleBooksClient.stub(:search, []) do
      with_cassette("open_library/search_harry_potter") do
        get search_results_path, params: { q: "harry potter" }
        assert_response :success
      end
    end
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

  private

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
end
