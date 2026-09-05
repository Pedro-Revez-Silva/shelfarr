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

  test "parses each release once while preserving its complete score" do
    search_result = @request.search_results.new(
      title: "The Name of the Wind - Patrick Rothfuss - English Audiobook M4B 128kbps",
      seeders: 50
    )
    expected = ReleaseScorer.score(search_result, @request)
    original_parse = ReleaseParserService.method(:parse)
    parsed_titles = []

    ReleaseParserService.stub(:parse, ->(title) { parsed_titles << title; original_parse.call(title) }) do
      assert_equal expected, ReleaseScorer.score(search_result, @request)
    end

    assert_equal [ search_result.title ], parsed_titles
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

  test "scores localized and original components of a combined title as aliases" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    book = Book.create!(
      title: "La Nena / The Girl",
      author: "Carmen Mola",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "es")

    localized = ReleaseScorer.score(
      SearchResult.new(title: "La Nena - Carmen Mola - Spanish EPUB", seeders: 50),
      request
    )
    original = ReleaseScorer.score(
      SearchResult.new(title: "The Girl - Carmen Mola - Spanish EPUB", seeders: 50),
      request
    )

    assert_equal 100, localized.breakdown[:title]
    assert_equal 100, original.breakdown[:title]
    assert_operator localized.total, :>=, 90
    assert_operator original.total, :>=, 90
    refute localized.breakdown[:auto_select_allowed]
    refute original.breakdown[:auto_select_allowed]

    combined = ReleaseScorer.score(
      SearchResult.new(title: "La Nena The Girl - Carmen Mola - Spanish EPUB", seeders: 50),
      request
    )
    assert combined.breakdown[:auto_select_allowed]
  end

  test "does not match a short combined-title alias inside another title" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    book = Book.create!(title: "Eso / It", author: "Stephen King", book_type: :ebook)
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")

    unrelated = ReleaseScorer.score(
      SearchResult.new(title: "The Institute - Stephen King - English EPUB", seeders: 50),
      request
    )
    exact = ReleaseScorer.score(
      SearchResult.new(title: "It - Stephen King - English EPUB", seeders: 50),
      request
    )

    assert_operator unrelated.breakdown[:title], :<, 100
    assert_equal 100, exact.breakdown[:title]
    assert_operator unrelated.total, :<, SettingsService.get(:auto_select_confidence_threshold, default: 90)
    refute unrelated.breakdown[:auto_select_allowed]
    refute exact.breakdown[:auto_select_allowed]
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

  test "accepts standard release delimiters after an exact comic issue" do
    book = Book.create!(
      title: "Saga",
      author: "Brian K. Vaughan",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-437-delimiters",
      issue_number: "54",
      series: "Saga",
      series_position: "54"
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")

    [
      "Saga.#054.English.Comic.CBZ",
      "Saga_#054_English_Comic_CBZ"
    ].each do |title|
      score = ReleaseScorer.score(SearchResult.new(title: title, seeders: 50), request)

      assert_equal :exact, score.breakdown[:issue_match], title
      assert_operator score.total, :>=, 80, title
      assert score.breakdown[:auto_select_allowed], title
    end
  end

  test "requires an explicit comic run year to match the series start year" do
    book = Book.create!(
      title: "Batman - #1 - The Legend of the Batman",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-438",
      issue_number: "1",
      series: "Batman",
      release_date: Date.new(2018, 4, 1),
      series_start_year: 1940
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")

    correct_titles = [
      "(1940) Batman #001 English Comic CBZ",
      "[1940] Batman #001 English Comic CBZ",
      "Batman (1940) #001 English Comic CBZ",
      "Batman [1940] #001 English Comic CBZ",
      "Batman #001 (1940) English Comic CBZ",
      "Batman #001 English Comic CBZ [1940]",
      "(1940) Batman #001 English Comic CBZ [1940]"
    ]
    conflicting_titles = [
      "(2016) Batman #001 English Comic CBZ",
      "[2016] Batman #001 English Comic CBZ",
      "Batman (2016) #001 English Comic CBZ",
      "Batman [2016] #001 English Comic CBZ",
      "Batman #001 (2016) English Comic CBZ",
      "Batman #001 English Comic CBZ [2016]",
      "Batman (1940) #001 English Comic CBZ [2016]",
      "Batman #001 English Comic CBZ [2018]"
    ]

    correct_titles.each do |title|
      score = ReleaseScorer.score(SearchResult.new(title: title, seeders: 50), request)

      assert_equal :exact, score.breakdown[:issue_match], title
      assert score.breakdown[:auto_select_allowed], title
    end
    conflicting_titles.each do |title|
      score = ReleaseScorer.score(SearchResult.new(title: title, seeders: 50), request)

      assert_equal :unknown, score.breakdown[:issue_match], title
      assert_operator score.total, :<, 50, title
      assert_not score.breakdown[:auto_select_allowed], title
    end
  end

  test "does not trust an explicit comic run year before volume metadata is backfilled" do
    book = Book.create!(
      title: "Batman - #1 - The Legend of the Batman",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-105811",
      issue_number: "1",
      series: "Batman",
      series_position: "1",
      series_start_year: nil
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")

    yearless_score = ReleaseScorer.score(
      SearchResult.new(title: "Batman #001 English Comic CBZ", seeders: 50),
      request
    )
    unverified_year_score = ReleaseScorer.score(
      SearchResult.new(title: "Batman #001 (2016) English Comic CBZ", seeders: 50),
      request
    )

    assert_equal :exact, yearless_score.breakdown[:issue_match]
    assert yearless_score.breakdown[:auto_select_allowed]
    assert_equal :unknown, unverified_year_score.breakdown[:issue_match]
    assert_operator unverified_year_score.total, :<, 50
    assert_not unverified_year_score.breakdown[:auto_select_allowed]
  end

  test "treats comic issue ranges and lists as ambiguous" do
    book = Book.create!(
      title: "Saga",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-439",
      issue_number: "1",
      series: "Saga"
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")

    [
      "Saga 1-12 English Comic CBZ",
      "Saga #001-#006 English Comic CBZ",
      "Saga #001,#002 English Comic CBZ",
      "Saga #001 #002 English Comic CBZ",
      "Saga #001/#002 English Comic CBZ",
      "Saga.#001.#002.English.Comic.CBZ",
      "Saga #001; #002 English Comic CBZ",
      "Saga #001 thru #006 English Comic CBZ",
      "Saga #001 through 006 English Comic CBZ",
      "Saga #001 (Digital) #002 English Comic CBZ"
    ].each do |title|
      score = ReleaseScorer.score(SearchResult.new(title: title, seeders: 50), request)

      assert_equal :unknown, score.breakdown[:issue_match], title
      assert_operator score.total, :>, 0, title
      assert_operator score.total, :<, 50, title
      assert_not score.breakdown[:auto_select_allowed], title
    end
  end

  test "treats explicitly marked year-shaped values as additional issues" do
    book = Book.create!(
      title: "2000 AD - #2000",
      book_type: :comicbook,
      content_kind: :graphic,
      issue_number: "2000",
      series: "2000 AD"
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")

    [
      "2000.AD #2000 and #2012 English Comic CBZ",
      "2000 AD #2000 plus issue 2012 English Comic CBZ",
      "2000 AD #2000 with No. #2012 English Comic CBZ",
      "2000 AD #2000 and number 2012 English Comic CBZ"
    ].each do |title|
      score = ReleaseScorer.score(SearchResult.new(title: title, seeders: 50), request)

      assert_equal :unknown, score.breakdown[:issue_match], title
      assert_not score.breakdown[:auto_select_allowed], title
    end

    unmarked_year = ReleaseScorer.score(
      SearchResult.new(title: "2000 AD #2000 published 2012 English Comic CBZ", seeders: 50),
      request
    )

    assert_equal :exact, unmarked_year.breakdown[:issue_match]
    assert unmarked_year.breakdown[:auto_select_allowed]
  end

  test "matches punctuated comic series without matching normalized lookalikes" do
    spider_man = Book.create!(
      title: "Spider-Man - #7",
      book_type: :comicbook,
      content_kind: :graphic,
      issue_number: "7",
      series: "Spider-Man"
    )
    spider_man_request = Request.create!(book: spider_man, user: @user, status: :pending, language: "en")

    exact = ReleaseScorer.score(SearchResult.new(title: "Spider-Man #7 English Comic CBZ", seeders: 50), spider_man_request)
    lookalike = ReleaseScorer.score(SearchResult.new(title: "Spiderwoman #7 English Comic CBZ", seeders: 50), spider_man_request)

    assert_equal :exact, exact.breakdown[:issue_match]
    assert_equal :unknown, lookalike.breakdown[:issue_match]

    x_series = Book.create!(
      title: "X - #7",
      book_type: :comicbook,
      content_kind: :graphic,
      issue_number: "7",
      series: "X"
    )
    x_request = Request.create!(book: x_series, user: @user, status: :pending, language: "en")

    assert_equal :exact,
      ReleaseScorer.score(SearchResult.new(title: "X #7 English Comic CBZ", seeders: 50), x_request).breakdown[:issue_match]
    assert_equal :unknown,
      ReleaseScorer.score(SearchResult.new(title: "10 #7 English Comic CBZ", seeders: 50), x_request).breakdown[:issue_match]

    numeric_series = Book.create!(
      title: "52 - #7",
      book_type: :comicbook,
      content_kind: :graphic,
      issue_number: "7",
      series: "52"
    )
    numeric_request = Request.create!(book: numeric_series, user: @user, status: :pending, language: "en")

    assert_equal :exact,
      ReleaseScorer.score(SearchResult.new(title: "52 #007 English Comic CBZ", seeders: 50), numeric_request).breakdown[:issue_match]
    assert_equal :exact,
      ReleaseScorer.score(SearchResult.new(title: "(1940) 52 #007 English Comic CBZ", seeders: 50), numeric_request).breakdown[:issue_match]
    assert_equal :unknown,
      ReleaseScorer.score(SearchResult.new(title: "Area 52 #007 English Comic CBZ", seeders: 50), numeric_request).breakdown[:issue_match]
    assert_equal :unknown,
      ReleaseScorer.score(SearchResult.new(title: "Batman #52 - #007 English Comic CBZ", seeders: 50), numeric_request).breakdown[:issue_match]
  end

  test "does not consume issue markers as numeric series punctuation" do
    [
      [ "X-23", "7", "X-23 #007 English Comic CBZ", "X #23 #007 English Comic CBZ" ],
      [ "Batman '66", "1", "Batman '66 #001 English Comic CBZ", "Batman #66 #001 English Comic CBZ" ]
    ].each do |series, issue, exact_title, conflicting_title|
      book = Book.create!(
        title: "#{series} - ##{issue}",
        book_type: :comicbook,
        content_kind: :graphic,
        issue_number: issue,
        series: series
      )
      request = Request.create!(book: book, user: @user, status: :pending, language: "en")

      exact = ReleaseScorer.score(SearchResult.new(title: exact_title, seeders: 50), request)
      conflicting = ReleaseScorer.score(SearchResult.new(title: conflicting_title, seeders: 50), request)

      assert_equal :exact, exact.breakdown[:issue_match], exact_title
      assert exact.breakdown[:auto_select_allowed], exact_title
      assert_equal :unknown, conflicting.breakdown[:issue_match], conflicting_title
      assert_not conflicting.breakdown[:auto_select_allowed], conflicting_title
    end
  end

  test "requires the comic series to occupy the leading release identity segment" do
    book = Book.create!(
      title: "X - #7",
      book_type: :comicbook,
      content_kind: :graphic,
      issue_number: "7",
      series: "X"
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")

    score = ReleaseScorer.score(
      SearchResult.new(title: "Generation X #007 English Comic CBZ", seeders: 50),
      request
    )

    assert_equal :unknown, score.breakdown[:issue_match]
    assert_operator score.total, :<, 50
    assert_not score.breakdown[:auto_select_allowed]
  end

  test "treats whitespace-separated issues as ambiguous but not a standalone year" do
    book = Book.create!(
      title: "Saga - #1",
      book_type: :comicbook,
      content_kind: :graphic,
      issue_number: "1",
      series: "Saga",
      release_date: Date.new(2012, 3, 14)
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")

    pack_score = ReleaseScorer.score(
      SearchResult.new(title: "Saga #001 002 English Comic CBZ", seeders: 50),
      request
    )
    year_score = ReleaseScorer.score(
      SearchResult.new(title: "Saga #001 2012 English Comic CBZ", seeders: 50),
      request
    )

    assert_equal :unknown, pack_score.breakdown[:issue_match]
    assert_not pack_score.breakdown[:auto_select_allowed]
    assert_equal :exact, year_score.breakdown[:issue_match]
    assert year_score.breakdown[:auto_select_allowed]
  end

  test "validates standalone release years outside the matched series and issue spans" do
    batman = Book.create!(
      title: "Batman - #1",
      book_type: :comicbook,
      content_kind: :graphic,
      issue_number: "1",
      series: "Batman",
      release_date: Date.new(2018, 4, 1),
      series_start_year: 1940
    )
    batman_request = Request.create!(book: batman, user: @user, status: :pending, language: "en")

    conflicting_titles = [
      "2016 Batman #001 English Comic CBZ",
      "Batman #001 English Comic CBZ 2016"
    ]
    matching_titles = [
      "1940 Batman #001 English Comic CBZ",
      "Batman #001 English Comic CBZ 1940"
    ]

    conflicting_titles.each do |title|
      score = ReleaseScorer.score(SearchResult.new(title: title, seeders: 50), batman_request)

      assert_equal :unknown, score.breakdown[:issue_match], title
      assert_not score.breakdown[:auto_select_allowed], title
    end
    matching_titles.each do |title|
      score = ReleaseScorer.score(SearchResult.new(title: title, seeders: 50), batman_request)

      assert_equal :exact, score.breakdown[:issue_match], title
      assert score.breakdown[:auto_select_allowed], title
    end

    numbered_series = Book.create!(
      title: "2000 AD - #7",
      book_type: :comicbook,
      content_kind: :graphic,
      issue_number: "7",
      series: "2000 AD",
      release_date: Date.new(1977, 3, 5)
    )
    numbered_request = Request.create!(book: numbered_series, user: @user, status: :pending, language: "en")
    numbered_score = ReleaseScorer.score(
      SearchResult.new(title: "2000.AD #007 English Comic CBZ", seeders: 50),
      numbered_request
    )
    assert_equal :exact, numbered_score.breakdown[:issue_match]

    high_issue = Book.create!(
      title: "Saga - #2000",
      book_type: :comicbook,
      content_kind: :graphic,
      issue_number: "2000",
      series: "Saga",
      release_date: Date.new(2024, 1, 1)
    )
    high_issue_request = Request.create!(book: high_issue, user: @user, status: :pending, language: "en")
    high_issue_score = ReleaseScorer.score(
      SearchResult.new(title: "Saga #2000 English Comic CBZ", seeders: 50),
      high_issue_request
    )
    assert_equal :exact, high_issue_score.breakdown[:issue_match]
  end

  test "normalizes padded numeric stems in comic issue labels" do
    [ [ "7A", "Saga 007A English Comic CBZ" ], [ "7.5", "Saga 007.5 English Comic CBZ" ] ].each do |issue, title|
      book = Book.create!(
        title: "Saga - ##{issue}",
        book_type: :comicbook,
        content_kind: :graphic,
        issue_number: issue,
        series: "Saga"
      )
      request = Request.create!(book: book, user: @user, status: :pending, language: "en")
      score = ReleaseScorer.score(SearchResult.new(title: title, seeders: 50), request)

      assert_equal :exact, score.breakdown[:issue_match], title
      assert score.breakdown[:auto_select_allowed], title
    end
  end

  test "requires a complete canonical comic issue label" do
    plain_issue = Book.create!(
      title: "Saga - #1",
      book_type: :comicbook,
      content_kind: :graphic,
      issue_number: "1",
      series: "Saga"
    )
    plain_request = Request.create!(book: plain_issue, user: @user, status: :pending, language: "en")
    suffixed_title = "Saga #1-A English Comic CBZ"

    ambiguous = ReleaseScorer.score(SearchResult.new(title: suffixed_title, seeders: 50), plain_request)

    assert_equal :unknown, ambiguous.breakdown[:issue_match]
    assert_not ambiguous.breakdown[:auto_select_allowed]
    assert_operator ambiguous.total, :<, 50

    suffixed_issue = Book.create!(
      title: "Saga - #1-A",
      book_type: :comicbook,
      content_kind: :graphic,
      issue_number: "1-A",
      series: "Saga"
    )
    suffixed_request = Request.create!(book: suffixed_issue, user: @user, status: :pending, language: "en")
    exact = ReleaseScorer.score(SearchResult.new(title: suffixed_title, seeders: 50), suffixed_request)

    assert_equal :exact, exact.breakdown[:issue_match]
    assert exact.breakdown[:auto_select_allowed]
  end

  test "does not interpret punctuation-extended series identities as unmarked issues" do
    [
      [ "X", "23", "X-23 English Comic CBZ" ],
      [ "Batman", "66", "Batman-66 English Comic CBZ" ],
      [ "52", "1", "52.1 English Comic CBZ" ]
    ].each do |series, issue, title|
      book = Book.create!(
        title: "#{series} - ##{issue}",
        book_type: :comicbook,
        content_kind: :graphic,
        issue_number: issue,
        series: series
      )
      request = Request.create!(book: book, user: @user, status: :pending, language: "en")
      score = ReleaseScorer.score(SearchResult.new(title: title, seeders: 50), request)

      assert_equal :unknown, score.breakdown[:issue_match], title
      assert_not score.breakdown[:auto_select_allowed], title
    end

    batman = Book.create!(
      title: "Batman - #1",
      book_type: :comicbook,
      content_kind: :graphic,
      issue_number: "1",
      series: "Batman"
    )
    request = Request.create!(book: batman, user: @user, status: :pending, language: "en")
    plain = ReleaseScorer.score(SearchResult.new(title: "Batman 001 English Comic CBZ", seeders: 50), request)

    assert_equal :exact, plain.breakdown[:issue_match]
    assert plain.breakdown[:auto_select_allowed]
  end

  test "treats any later standalone issue-shaped number as ambiguous" do
    book = Book.create!(
      title: "Saga - #1",
      book_type: :comicbook,
      content_kind: :graphic,
      issue_number: "1",
      series: "Saga",
      release_date: Date.new(2012, 3, 14)
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")

    [
      "Saga #1 y 2 English Comic CBZ",
      "Saga #1 et 2 English Comic CBZ",
      "Saga #1 und 2 English Comic CBZ",
      "Saga #1 plus 2 English Comic CBZ"
    ].each do |title|
      score = ReleaseScorer.score(SearchResult.new(title: title, seeders: 50), request)

      assert_equal :unknown, score.breakdown[:issue_match], title
      assert_not score.breakdown[:auto_select_allowed], title
    end

    matching_year = ReleaseScorer.score(
      SearchResult.new(title: "Saga #1 published 2012 English Comic CBZ", seeders: 50),
      request
    )

    assert_equal :exact, matching_year.breakdown[:issue_match]
    assert matching_year.breakdown[:auto_select_allowed]
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
