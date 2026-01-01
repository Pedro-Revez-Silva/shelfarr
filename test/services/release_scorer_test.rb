# frozen_string_literal: true

require "test_helper"

class ReleaseScorerTest < ActiveSupport::TestCase
  setup do
    @book = Book.create!(
      title: "The Name of the Wind",
      author: "Patrick Rothfuss",
      book_type: :audiobook
    )

    @user = users(:one)

    @request = Request.create!(
      book: @book,
      user: @user,
      status: :pending,
      language: "en"
    )
  end

  test "scores high for exact title match with correct language" do
    search_result = @request.search_results.create!(
      guid: "test-1",
      title: "The Name of the Wind - Patrick Rothfuss - English Audiobook M4B",
      seeders: 50
    )

    result = ReleaseScorer.score(search_result, @request)

    assert result.total >= 80
    assert_includes result.detected_languages, "en"
    assert_equal :audiobook, result.detected_format
  end

  test "scores low for wrong language" do
    search_result = @request.search_results.create!(
      guid: "test-2",
      title: "De Naam Van De Wind - Dutch Audiobook",
      seeders: 50
    )

    result = ReleaseScorer.score(search_result, @request)

    assert result.total < 70
    assert_includes result.detected_languages, "nl"
  end

  test "scores neutral when no language detected" do
    search_result = @request.search_results.create!(
      guid: "test-3",
      title: "The Name of the Wind Audiobook M4B",
      seeders: 50
    )

    result = ReleaseScorer.score(search_result, @request)

    assert_empty result.detected_languages
    assert result.breakdown[:language] == 50
  end

  test "scores high for multi-language release" do
    search_result = @request.search_results.create!(
      guid: "test-4",
      title: "The Name of the Wind MULTI Audiobook",
      seeders: 50
    )

    result = ReleaseScorer.score(search_result, @request)

    assert result.breakdown[:language] == 100
  end

  test "scores format match correctly for audiobook" do
    search_result = @request.search_results.create!(
      guid: "test-5",
      title: "The Name of the Wind Unabridged M4B",
      seeders: 50
    )

    result = ReleaseScorer.score(search_result, @request)

    assert_equal :audiobook, result.detected_format
    assert result.breakdown[:format] == 100
  end

  test "scores format mismatch for ebook when audiobook requested" do
    search_result = @request.search_results.create!(
      guid: "test-6",
      title: "The Name of the Wind EPUB",
      seeders: 50
    )

    result = ReleaseScorer.score(search_result, @request)

    assert_equal :ebook, result.detected_format
    assert result.breakdown[:format] == 0
  end

  test "scores author presence correctly" do
    search_result = @request.search_results.create!(
      guid: "test-7",
      title: "The Name of the Wind - Patrick Rothfuss",
      seeders: 50
    )

    result = ReleaseScorer.score(search_result, @request)

    assert result.breakdown[:author] == 100
  end

  test "scores partial author match for last name only" do
    search_result = @request.search_results.create!(
      guid: "test-8",
      title: "The Name of the Wind - Rothfuss Audiobook",
      seeders: 50
    )

    result = ReleaseScorer.score(search_result, @request)

    assert result.breakdown[:author] == 80
  end

  test "scores health based on seeders" do
    search_result = @request.search_results.create!(
      guid: "test-9",
      title: "The Name of the Wind",
      seeders: 0
    )

    result = ReleaseScorer.score(search_result, @request)

    assert result.breakdown[:health] == 0
  end

  test "scores health high for many seeders" do
    search_result = @request.search_results.create!(
      guid: "test-10",
      title: "The Name of the Wind",
      seeders: 100
    )

    result = ReleaseScorer.score(search_result, @request)

    assert result.breakdown[:health] >= 90
  end

  test "high_confidence returns true for score >= 90" do
    result = ReleaseScorer::Result.new(
      total: 92,
      breakdown: {},
      detected_languages: [],
      detected_format: nil
    )

    assert result.high_confidence?
    refute result.medium_confidence?
    refute result.low_confidence?
  end

  test "medium_confidence returns true for score 70-89" do
    result = ReleaseScorer::Result.new(
      total: 75,
      breakdown: {},
      detected_languages: [],
      detected_format: nil
    )

    refute result.high_confidence?
    assert result.medium_confidence?
    refute result.low_confidence?
  end

  test "low_confidence returns true for score < 70" do
    result = ReleaseScorer::Result.new(
      total: 45,
      breakdown: {},
      detected_languages: [],
      detected_format: nil
    )

    refute result.high_confidence?
    refute result.medium_confidence?
    assert result.low_confidence?
  end
end
