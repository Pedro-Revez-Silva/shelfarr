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

    SettingsService.set(:audiobook_approved_formats, [])
    SettingsService.set(:audiobook_rejected_formats, [])
    SettingsService.set(:audiobook_preferred_formats, [])
    SettingsService.set(:audiobook_prefer_single_file, false)
    SettingsService.set(:audiobook_prefer_higher_bitrate, false)
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

  test "preferred audiobook format increases score" do
    SettingsService.set(:audiobook_preferred_formats, [ "m4b", "mp3" ])

    m4b_result = @request.search_results.create!(
      guid: "test-pref-m4b",
      title: "The Name of the Wind English Audiobook M4B",
      seeders: 25
    )
    mp3_result = @request.search_results.create!(
      guid: "test-pref-mp3",
      title: "The Name of the Wind English Audiobook MP3",
      seeders: 25
    )

    m4b_score = ReleaseScorer.score(m4b_result, @request)
    mp3_score = ReleaseScorer.score(mp3_result, @request)

    assert_operator m4b_score.total, :>, mp3_score.total
    assert_equal "m4b", m4b_score.breakdown[:extension]
    assert_equal "mp3", mp3_score.breakdown[:extension]
  end

  test "rejected audiobook format blocks auto selection" do
    SettingsService.set(:audiobook_rejected_formats, [ "mp3" ])

    search_result = @request.search_results.create!(
      guid: "test-rejected-format",
      title: "The Name of the Wind English Audiobook MP3",
      seeders: 50
    )

    result = ReleaseScorer.score(search_result, @request)

    refute result.breakdown[:auto_select_allowed]
    assert_operator result.breakdown[:preference_adjustment], :<=, -35
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

  test "treats roman and arabic series numbers as equivalent in title matching" do
    book = Book.create!(
      title: "The Perfect Run III",
      author: "Maxime Durand",
      book_type: :audiobook
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    search_result = request.search_results.create!(
      guid: "perfect-run-3",
      title: "The Perfect Run 3 - Maxime Durand - English Audiobook M4B",
      seeders: 50
    )

    result = ReleaseScorer.score(search_result, request)

    assert_equal 100, result.breakdown[:title]
    assert result.total >= 80
  end

  test "treats arabic book numbers and roman release numbers as equivalent in title matching" do
    book = Book.create!(
      title: "The Perfect Run 3",
      author: "Maxime Durand",
      book_type: :audiobook
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    search_result = request.search_results.create!(
      guid: "perfect-run-iii",
      title: "The Perfect Run III - Maxime Durand - English Audiobook M4B",
      seeders: 50
    )

    result = ReleaseScorer.score(search_result, request)

    assert_equal 100, result.breakdown[:title]
  end

  test "rewards an exact comic issue and rejects a conflicting issue" do
    book = Book.create!(
      title: "Saga",
      author: "Brian K. Vaughan",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-437",
      issue_number: "7",
      series: "Saga",
      series_position: "7"
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    exact = SearchResult.new(title: "Saga #7 English Comic CBZ", seeders: 50)
    conflicting = SearchResult.new(title: "Saga #8 English Comic CBZ", seeders: 50)

    exact_score = ReleaseScorer.score(exact, request)
    conflicting_score = ReleaseScorer.score(conflicting, request)

    assert_operator exact_score.total, :>, conflicting_score.total
    assert_operator exact_score.total, :>=, 90
    assert_equal :exact, exact_score.breakdown[:issue_match]
    assert_equal "7", exact_score.breakdown[:detected_issue_number]
    assert_equal :mismatch, conflicting_score.breakdown[:issue_match]
    assert_equal 0, conflicting_score.total
    assert_not conflicting_score.breakdown[:auto_select_allowed]
  end

  test "does not reject a comic release containing an ambiguous issue range" do
    book = Book.create!(
      title: "Saga",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-439",
      issue_number: "7",
      series: "Saga"
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    release = SearchResult.new(title: "Saga 1-12 English Comic CBZ", seeders: 50)

    score = ReleaseScorer.score(release, request)

    assert_equal :unknown, score.breakdown[:issue_match]
    assert_operator score.total, :>, 0
    assert_operator score.total, :<, 50
    assert_not score.breakdown[:auto_select_allowed]
  end

  test "does not reject conflicting alphanumeric comic issue labels" do
    book = Book.create!(
      title: "Saga",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-440",
      issue_number: "7A",
      series: "Saga"
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    exact = SearchResult.new(title: "Saga #7A English Comic CBZ", seeders: 50)
    conflicting = SearchResult.new(title: "Saga #7B English Comic CBZ", seeders: 50)

    exact_score = ReleaseScorer.score(exact, request)
    conflicting_score = ReleaseScorer.score(conflicting, request)

    assert_equal :exact, exact_score.breakdown[:issue_match]
    assert_equal :unknown, conflicting_score.breakdown[:issue_match]
    assert_operator conflicting_score.total, :>, 0
    assert_operator conflicting_score.total, :<, 50
    assert_not conflicting_score.breakdown[:auto_select_allowed]
  end

  test "does not treat a Comic Vine volume position as an issue number" do
    book = Book.create!(
      title: "Saga Deluxe Volume",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4050-442",
      issue_number: nil,
      series: "Saga",
      series_position: "7"
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    release = SearchResult.new(title: "Saga Deluxe Volume English Comic CBZ", seeders: 50)

    score = ReleaseScorer.score(release, request)

    assert_not score.breakdown.key?(:issue_match)
    assert score.breakdown[:auto_select_allowed]
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
