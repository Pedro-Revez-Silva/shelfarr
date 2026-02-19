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
  end

  test "results returns search results" do
    with_cassette("open_library/search_harry_potter") do
      get search_results_path, params: { q: "harry potter" }
      assert_response :success
    end
  end

  test "results with empty query returns empty results" do
    get search_results_path, params: { q: "" }
    assert_response :success
  end

  test "results handles turbo stream format" do
    with_cassette("open_library/search_fiction") do
      get search_results_path, params: { q: "fiction" }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :success
      assert_match "turbo-stream", response.body
    end
  end

  test "results shows warning when matching audiobookshelf item exists" do
    LibraryItem.destroy_all
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-1",
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      synced_at: Time.current
    )

    result = Struct.new(:work_id, :title, :author, :cover_url, :first_publish_year, keyword_init: true)
    metadata_result = result.new(
      work_id: "work-hobbit",
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      first_publish_year: 1937
    )

    MetadataService.stub(:search, [metadata_result]) do
      get search_results_path, params: { q: "hobbit" }
    end

    assert_response :success
    assert_match "Similar book may already exist", response.body
  end

  test "results does not show warning when no similar audiobookshelf item exists" do
    LibraryItem.destroy_all
    LibraryItem.create!(
      library_id: "lib-audio",
      audiobookshelf_id: "ab-1",
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      synced_at: Time.current
    )

    result = Struct.new(:work_id, :title, :author, :cover_url, :first_publish_year, keyword_init: true)
    metadata_result = result.new(
      work_id: "work-1984",
      title: "1984",
      author: "George Orwell",
      first_publish_year: 1949
    )

    MetadataService.stub(:search, [metadata_result]) do
      get search_results_path, params: { q: "1984" }
    end

    assert_response :success
    assert_no_match "Similar book may already exist", response.body
  end
end
