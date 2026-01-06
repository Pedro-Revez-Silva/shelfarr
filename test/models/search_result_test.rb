# frozen_string_literal: true

require "test_helper"

class SearchResultTest < ActiveSupport::TestCase
  setup do
    @pending_result = search_results(:pending_result)
    @selected_result = search_results(:selected_result)
    @no_link_result = search_results(:no_link_result)
  end

  # === Validations ===

  test "requires guid" do
    result = SearchResult.new(request: requests(:pending_request), title: "Test")
    assert_not result.valid?
    assert_includes result.errors[:guid], "can't be blank"
  end

  test "requires title" do
    result = SearchResult.new(request: requests(:pending_request), guid: "test-guid")
    assert_not result.valid?
    assert_includes result.errors[:title], "can't be blank"
  end

  test "guid must be unique per request" do
    result = SearchResult.new(
      request: @pending_result.request,
      guid: @pending_result.guid,
      title: "Duplicate"
    )
    assert_not result.valid?
    assert_includes result.errors[:guid], "has already been taken"
  end

  test "same guid allowed on different requests" do
    other_request = requests(:failed_request)
    result = SearchResult.new(
      request: other_request,
      guid: @pending_result.guid,
      title: "Same GUID, different request"
    )
    assert result.valid?
  end

  # === Scopes ===

  test "selectable returns only pending results" do
    selectable = SearchResult.selectable
    assert_includes selectable, @pending_result
    assert_not_includes selectable, @selected_result
  end

  test "best_first orders by seeders desc then size asc" do
    request = requests(:pending_request)
    request.search_results.destroy_all

    low_seeders = request.search_results.create!(guid: "low", title: "Low", seeders: 10, size_bytes: 100)
    high_seeders = request.search_results.create!(guid: "high", title: "High", seeders: 50, size_bytes: 200)
    same_seeders_small = request.search_results.create!(guid: "same-small", title: "Same Small", seeders: 30, size_bytes: 100)
    same_seeders_large = request.search_results.create!(guid: "same-large", title: "Same Large", seeders: 30, size_bytes: 500)

    ordered = request.search_results.best_first.to_a
    assert_equal high_seeders, ordered[0]
    assert_equal same_seeders_small, ordered[1]
    assert_equal same_seeders_large, ordered[2]
    assert_equal low_seeders, ordered[3]
  end

  # === Methods ===

  test "downloadable? returns true when magnet_url present" do
    assert @pending_result.downloadable?
  end

  test "downloadable? returns true when download_url present" do
    assert @selected_result.downloadable?
  end

  test "downloadable? returns false when no links" do
    assert_not @no_link_result.downloadable?
  end

  test "downloadable? returns true for Anna's Archive results even without links" do
    anna_result = SearchResult.new(
      request: requests(:pending_request),
      guid: "anna-test-md5",
      title: "Anna's Archive Book",
      source: SearchResult::SOURCE_ANNA_ARCHIVE,
      download_url: nil,
      magnet_url: nil
    )
    assert anna_result.downloadable?, "Anna's Archive results should always be downloadable via API"
  end

  test "download_link prefers magnet_url over download_url" do
    result = SearchResult.new(
      magnet_url: "magnet:?xt=test",
      download_url: "http://example.com/download"
    )
    assert_equal "magnet:?xt=test", result.download_link
  end

  test "download_link falls back to download_url" do
    assert_equal "http://example.com/download/test.torrent", @selected_result.download_link
  end

  test "size_human returns human readable size" do
    assert_equal "1 GB", @pending_result.size_human
    assert_equal "500 MB", @selected_result.size_human
  end

  test "size_human returns nil when no size" do
    result = SearchResult.new
    assert_nil result.size_human
  end
end
