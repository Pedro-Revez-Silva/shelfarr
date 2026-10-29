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

  test "scores dotted scene-style release titles the same as spaced exact matches" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])

    book = Book.create!(
      title: "Vielleicht bin ich nicht Gott. Chroniken einer Katze",
      author: "Stefania Gander",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "de")

    spaced = ReleaseScorer.score(
      SearchResult.new(title: "Stefania Gander - Vielleicht bin ich nicht Gott - Chroniken einer Katze", seeders: 50),
      request
    )
    dotted_with_separators = ReleaseScorer.score(
      SearchResult.new(title: "Stefania.Gander.-.Vielleicht.bin.ich.nicht.Gott.-.Chroniken.einer.Katze", seeders: 50),
      request
    )
    dotted = ReleaseScorer.score(
      SearchResult.new(title: "Stefania.Gander.Vielleicht.bin.ich.nicht.Gott.Chroniken.einer.Katze", seeders: 50),
      request
    )

    assert_equal 100, spaced.breakdown[:title]
    assert_equal 100, dotted_with_separators.breakdown[:title]
    assert_equal 100, dotted.breakdown[:title]
    assert_equal spaced.breakdown[:title], dotted_with_separators.breakdown[:title]
    assert_equal spaced.breakdown[:title], dotted.breakdown[:title]
  end

  test "transliterates non-ASCII title letters instead of deleting them" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])

    book = Book.create!(
      title: "Spaß in der Küche",
      author: "Jürgen Weiß",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "de")

    native = ReleaseScorer.score(
      SearchResult.new(title: "Spaß in der Küche - Jürgen Weiß", seeders: 50),
      request
    )
    ascii = ReleaseScorer.score(
      SearchResult.new(title: "Spass in der Kuche - Jurgen Weiss", seeders: 50),
      request
    )

    assert_equal 100, native.breakdown[:title]
    assert_equal 100, ascii.breakdown[:title]
    assert_equal native.breakdown[:title], ascii.breakdown[:title]
  end

  test "preserves exact title and author matches with curly apostrophes" do
    [ "'", "’", "‘" ].each do |apostrophe|
      @book.update!(title: "Ender#{apostrophe}s Game", author: "O#{apostrophe}Connor")
      release = @request.search_results.new(
        title: "Enders Game OConnor English Audiobook M4B",
        seeders: 50
      )

      score = ReleaseScorer.score(release, @request)

      assert_equal 100, score.breakdown[:title]
      assert_equal 100, score.breakdown[:author]
      assert score.high_confidence?
      assert score.breakdown[:auto_select_allowed]
    end
  end

  test "scores elided apostrophe titles as exact matches against dotted scene releases" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    SettingsService.set(:auto_select_confidence_threshold, 90)
    @request.update!(language: "fr")
    threshold = SettingsService.get(:auto_select_confidence_threshold, default: 90)

    [ "'", "’", "‘" ].each do |apostrophe|
      [
        [ "C#{apostrophe}est Random Title", "Some Author", "C.est.Random.Title.Some.Author.2026.Fr.[ePub]" ],
        [ "D#{apostrophe}Artagnan", "Alexandre Dumas", "D.Artagnan.Alexandre.Dumas.2026.Fr.[ePub]" ],
        [ "L#{apostrophe}Étranger", "Albert Camus", "L.Etranger.Albert.Camus.2026.Fr.[ePub]" ],
        [ "J#{apostrophe}irai cracher sur vos tombes", "Boris Vian", "J.irai.cracher.sur.vos.tombes.Boris.Vian.2026.Fr.[ePub]" ],
        [ "N#{apostrophe}importe quoi", "Some Author", "N.importe.quoi.Some.Author.2026.Fr.[ePub]" ],
        [ "S#{apostrophe}il vous plait", "Some Author", "S.il.vous.plait.Some.Author.2026.Fr.[ePub]" ],
        [ "Qu#{apostrophe}est-ce que c#{apostrophe}est", "Some Author", "Qu.est.ce.que.c.est.Some.Author.2026.Fr.[ePub]" ]
      ].each do |title, author, release_title|
        @book.update!(title: title, author: author, book_type: :ebook)
        score = ReleaseScorer.score(
          @request.search_results.new(title: release_title, seeders: 50),
          @request
        )

        assert_equal 100, score.breakdown[:title], "#{title} => #{score.breakdown.inspect}"
        assert_operator score.total, :>=, threshold, "#{title} total #{score.total} is below auto-select confidence"
        assert score.high_confidence?, "#{title} total #{score.total}"
        assert score.breakdown[:auto_select_allowed], title
      end
    end
  end

  test "keeps exact matches for English contractions" do
    @book.update!(title: "Ender's Game", author: "Orson Scott Card")
    [
      "Ender's Game Orson Scott Card English Audiobook M4B",
      "Enders Game Orson Scott Card English Audiobook M4B",
      "Enders.Game.Orson.Scott.Card.English.Audiobook.M4B"
    ].each do |release_title|
      score = ReleaseScorer.score(
        @request.search_results.new(title: release_title, seeders: 50),
        @request
      )

      assert_equal 100, score.breakdown[:title], release_title
      assert_equal 100, score.breakdown[:author], release_title
      assert score.high_confidence?, "#{release_title} total #{score.total}"
      assert score.breakdown[:auto_select_allowed], release_title
    end
  end

  test "matches canonically decomposed accents in titles and authors" do
    @book.update!(
      title: "Die Bücherdiebin".unicode_normalize(:nfd),
      author: "Jürgen Weiß".unicode_normalize(:nfd)
    )

    [ "Die Bucherdiebin Jurgen Weiss", "Die Bücherdiebin Jürgen Weiß".unicode_normalize(:nfd) ].each do |name|
      release = @request.search_results.new(title: "#{name} English Audiobook M4B", seeders: 50)
      score = ReleaseScorer.score(release, @request)

      assert_equal 100, score.breakdown[:title]
      assert_equal 100, score.breakdown[:author]
      assert score.high_confidence?
    end
  end

  test "preserves punctuationless title and author matches" do
    [
      [ "Catch-22", "Joseph Heller", "Catch22 Joseph Heller" ],
      [ "Catch22", "Joseph Heller", "Catch-22 Joseph Heller" ],
      [ "R.U.R.", "Karel Capek", "RUR Karel Capek" ],
      [ "The Hobbit", "J.R.R. Tolkien", "The Hobbit JRR Tolkien" ]
    ].each do |title, author, release_title|
      @book.update!(title: title, author: author)
      release = @request.search_results.new(title: "#{release_title} English Audiobook M4B", seeders: 50)
      score = ReleaseScorer.score(release, @request)

      assert_equal 100, score.breakdown[:title], title
      assert_equal 100, score.breakdown[:author], author
      assert score.high_confidence?
      assert score.breakdown[:auto_select_allowed]
    end
  end

  test "does not crash or award an author match when transliteration has no matching letters" do
    @book.update!(title: "The Three Body Problem", author: "刘慈欣")
    release = @request.search_results.new(title: "The Three Body Problem English Audiobook M4B", seeders: 50)
    score = ReleaseScorer.score(release, @request)

    assert_equal 100, score.breakdown[:title]
    assert_equal 0, score.breakdown[:author]
    assert_not score.high_confidence?
  end

  test "does not treat R.U.R. as a short title" do
    key = TitleKey.new("R.U.R.")

    assert_equal "r u r", key.canonical
    assert_includes key.forms, "rur"
    assert_not key.short?
    assert TitleKey.new("RUR").short?

    @book.update!(title: "R.U.R.", author: "Karel Capek")
    [
      "RUR Karel Capek",
      "Collected RUR Karel Capek",
      "Collected R.U.R. Karel Capek"
    ].each do |release_title|
      score = ReleaseScorer.score(@request.search_results.new(title: release_title), @request)

      assert_equal 100, score.breakdown[:title], release_title
    end
  end

  test "punctuationless title matching preserves phrase and short alias boundaries" do
    [
      [ "Catch-22", "Catch220 Joseph Heller" ],
      [ "Catch-22", "Scatch22 Joseph Heller" ],
      [ "RUR", "Collected R.U.R. Karel Capek" ]
    ].each do |title, release_title|
      @book.update!(title: title)
      score = ReleaseScorer.score(@request.search_results.new(title: release_title), @request)

      assert_operator score.breakdown[:title], :<, 100, release_title
    end

    @book.update!(title: "Catch-22 / R.U.R.")
    partial = ReleaseScorer.score(@request.search_results.new(title: "Catch22 English Audiobook M4B"), @request)
    full = ReleaseScorer.score(@request.search_results.new(title: "Catch22 RUR English Audiobook M4B"), @request)

    assert_equal 100, partial.breakdown[:title]
    assert_not partial.breakdown[:auto_select_allowed]
    assert_equal 100, full.breakdown[:title]
    assert full.breakdown[:auto_select_allowed]
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

  test "scores a cross-language volume marker as an exact title match" do
    score_for = lambda do |title, release_title|
      book = Book.create!(title: title, author: "Andrzej Sapkowski", book_type: :ebook)
      request = Request.create!(book: book, user: @user, status: :pending, language: "en")
      ReleaseScorer.score(SearchResult.new(title: release_title, seeders: 50), request)
    end
    baseline = score_for.call(
      "The Witcher Part 2",
      "The Witcher Part 2 - Andrzej Sapkowski EPUB"
    )

    assert_equal 100, baseline.breakdown[:title]
    [
      "The Witcher Tome 2 - Andrzej Sapkowski EPUB",
      "The Witcher Partie 2 - Andrzej Sapkowski EPUB",
      "The Witcher Livre 2 - Andrzej Sapkowski EPUB",
      "The Witcher T2 - Andrzej Sapkowski EPUB",
      "The Witcher T.2 - Andrzej Sapkowski EPUB",
      "The Witcher T02 - Andrzej Sapkowski EPUB",
      "The Witcher Band 2 - Andrzej Sapkowski EPUB",
      "The Witcher Teil 2 - Andrzej Sapkowski EPUB",
      "The Witcher Buch 2 - Andrzej Sapkowski EPUB",
      "The Witcher Tomo 2 - Andrzej Sapkowski EPUB",
      "The Witcher Parte 2 - Andrzej Sapkowski EPUB",
      "The Witcher Libro 2 - Andrzej Sapkowski EPUB",
      "The Witcher Livro 2 - Andrzej Sapkowski EPUB",
      "The Witcher Volumen 2 - Andrzej Sapkowski EPUB",
      "The Witcher Deel 2 - Andrzej Sapkowski EPUB",
      "The Witcher Boek 2 - Andrzej Sapkowski EPUB",
      "The Witcher Tome II - Andrzej Sapkowski EPUB",
      "The Witcher Part. 2 - Andrzej Sapkowski EPUB",
      "The Witcher Volume 2 - Andrzej Sapkowski EPUB",
      "The Witcher Book 2 - Andrzej Sapkowski EPUB"
    ].each do |release_title|
      score = score_for.call("The Witcher Part 2", release_title)

      assert_equal baseline.breakdown[:title], score.breakdown[:title], release_title
      assert_equal baseline.total, score.total, release_title
    end
  end

  test "scores agreeing split-volume numbers as an exact title match" do
    book = Book.create!(
      title: "Chronicles of the Northern Sea Tome 3 Partie 1",
      author: "Ada Lovelace",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(title: "Chronicles of the Northern Sea Book 3 Part 1 - Ada Lovelace EPUB", seeders: 50),
      request
    )

    assert_equal 100, score.breakdown[:title]
  end

  test "does not score a different volume number as the same title" do
    book = Book.create!(
      title: "Chronicles of the Northern Sea Book 2",
      author: "Ada Lovelace",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(title: "Chronicles of the Northern Sea Tome 3 - Ada Lovelace EPUB", seeders: 50),
      request
    )

    assert_equal 0, score.breakdown[:title]
  end

  test "does not score pocket splits that differ by part as the same title" do
    book = Book.create!(
      title: "Chronicles of the Northern Sea Tome 3 Partie 1",
      author: "Ada Lovelace",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(title: "Chronicles of the Northern Sea Tome 3 Partie 2 - Ada Lovelace EPUB", seeders: 50),
      request
    )

    assert_equal 0, score.breakdown[:title]
  end

  test "scores abbreviated author initials above the auto-select threshold" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    book = Book.create!(title: "The Red Book", author: "Carl Gustav Jung", book_type: :ebook)
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(title: "The Red Book C. G. Jung English EPUB", seeders: 50),
      request
    )

    assert_equal 100, score.breakdown[:title], score.breakdown.inspect
    assert_operator score.total, :>=, 90, "total #{score.total} breakdown #{score.breakdown.inspect}"
    assert score.high_confidence?, score.total.to_s
  end

  test "scores a parenthesized publication year above the auto-select threshold" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    book = Book.create!(title: "The Jungle Book", author: "Rudyard Kipling", book_type: :ebook)
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(title: "Rudyard Kipling - The Jungle Book (1894) English EPUB", seeders: 50),
      request
    )

    assert_equal 100, score.breakdown[:title], score.breakdown.inspect
    assert_operator score.total, :>=, 90, "total #{score.total} breakdown #{score.breakdown.inspect}"
    assert score.high_confidence?, score.total.to_s
  end

  test "scores a possessive author title above the auto-select threshold" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    book = Book.create!(
      title: "William Shakespeare's Hamlet",
      author: "William Shakespeare",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(
        title: "William Shakespeare's Hamlet - William Shakespeare English EPUB",
        seeders: 50
      ),
      request
    )

    assert_equal 100, score.breakdown[:title], score.breakdown.inspect
    assert_operator score.total, :>=, 90, "total #{score.total} breakdown #{score.breakdown.inspect}"
    assert score.high_confidence?, score.total.to_s
  end

  test "does not score author initials as a volume marker" do
    book = Book.create!(title: "The Red Book", author: "C. G. Jung", book_type: :ebook)
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(title: "The Red Book C. G. Jung English EPUB", seeders: 50),
      request
    )

    assert_equal 100, score.breakdown[:title]
  end

  test "still scores a real volume when the release also names the author" do
    book = Book.create!(title: "The Red Book Volume 2", author: "C. G. Jung", book_type: :ebook)
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    matching = ReleaseScorer.score(
      SearchResult.new(title: "The Red Book Volume 2 C. G. Jung English EPUB", seeders: 50),
      request
    )
    conflicting = ReleaseScorer.score(
      SearchResult.new(title: "The Red Book Volume 3 C. G. Jung English EPUB", seeders: 50),
      request
    )

    assert_equal 100, matching.breakdown[:title]
    assert_equal 0, conflicting.breakdown[:title]
  end

  test "scores a contraction the same as the title without inventing a volume" do
    book = Book.create!(title: "Don't I Know You?", author: "Ada Lovelace", book_type: :ebook)
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(title: "Dont I Know You Ada Lovelace EPUB", seeders: 50),
      request
    )

    assert_equal 100, score.breakdown[:title]
  end

  test "scores a hyphenated part release as the spaced part" do
    book = Book.create!(title: "Dune Part 2", author: "Frank Herbert", book_type: :ebook)
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(title: "Dune Part-2 - Frank Herbert EPUB", seeders: 50),
      request
    )

    assert_equal 100, score.breakdown[:title]
  end

  test "scores a hashed volume marker as the spelled volume" do
    book = Book.create!(title: "Bleach Volume 2", author: "Tite Kubo", book_type: :ebook)
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(title: "Bleach Vol. #2 Tite Kubo EPUB", seeders: 50),
      request
    )

    assert_equal 100, score.breakdown[:title]
  end

  test "does not treat an unnumbered marker word as a volume while scoring" do
    brothers = Book.create!(title: "Band of Brothers", author: "Stephen E. Ambrose", book_type: :ebook)
    parte = Book.create!(title: "La parte oscura del libro", author: "Mariana Enriquez", book_type: :ebook)
    brothers_request = Request.create!(book: brothers, user: @user, status: :pending, language: "en")
    parte_request = Request.create!(book: parte, user: @user, status: :pending, language: "es")

    assert_equal 100, ReleaseScorer.score(
      SearchResult.new(title: "Band of Brothers - Stephen E. Ambrose EPUB", seeders: 50),
      brothers_request
    ).breakdown[:title]
    assert_operator ReleaseScorer.score(
      SearchResult.new(title: "Tome 2 - Stephen E. Ambrose EPUB", seeders: 50),
      brothers_request
    ).breakdown[:title], :<, 100
    assert_equal 100, ReleaseScorer.score(
      SearchResult.new(title: "La parte oscura del libro - Mariana Enriquez EPUB", seeders: 50),
      parte_request
    ).breakdown[:title]
    assert_operator ReleaseScorer.score(
      SearchResult.new(title: "Libro 2 - Mariana Enriquez EPUB", seeders: 50),
      parte_request
    ).breakdown[:title], :<, 100
  end

  test "scores an underscored volume marker above the auto-select threshold" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    book = Book.create!(title: "Attack on Titan Vol 2", author: "Hajime Isayama", book_type: :ebook)
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(title: "Attack_on_Titan_Vol_2 - Hajime Isayama English EPUB", seeders: 50),
      request
    )

    assert_equal 100, score.breakdown[:title], score.breakdown.inspect
    assert_operator score.total, :>=, 90, "total #{score.total} breakdown #{score.breakdown.inspect}"
    assert score.high_confidence?, score.total.to_s
  end

  test "scores a dotted possessive title above the auto-select threshold" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    book = Book.create!(
      title: "William Shakespeare's Hamlet",
      author: "William Shakespeare",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(
        title: "William.Shakespeare.s.Hamlet.-.William.Shakespeare.English.EPUB",
        seeders: 50
      ),
      request
    )

    assert_equal 100, score.breakdown[:title], score.breakdown.inspect
    assert_operator score.total, :>=, 90, "total #{score.total} breakdown #{score.breakdown.inspect}"
    assert score.high_confidence?, score.total.to_s
  end

  test "scores undotted author initials above the auto-select threshold" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    book = Book.create!(title: "The Red Book", author: "Carl Gustav Jung", book_type: :ebook)
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")

    [
      "The Red Book C G Jung English EPUB",
      "The Red Book C. Jung English EPUB"
    ].each do |release_title|
      score = ReleaseScorer.score(
        SearchResult.new(title: release_title, seeders: 50),
        request
      )

      assert_equal 100, score.breakdown[:title], "#{release_title} #{score.breakdown.inspect}"
      assert_operator score.total, :>=, 90, "#{release_title} total #{score.total} breakdown #{score.breakdown.inspect}"
      assert score.high_confidence?, "#{release_title} #{score.total}"
    end
  end

  test "scores the author inside the title when only the volume marker differs" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    book = Book.create!(
      title: "The Collected Works of C. G. Jung Volume 1",
      author: "C. G. Jung",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(
        title: "The Collected Works of C. G. Jung Band 1 - C. G. Jung English EPUB",
        seeders: 50
      ),
      request
    )

    assert_equal 100, score.breakdown[:title], score.breakdown.inspect
    assert_operator score.total, :>=, 90, "total #{score.total} breakdown #{score.breakdown.inspect}"
  end

  test "scores a curly apostrophe volume against a straight apostrophe release" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    book = Book.create!(
      title: "L\u2019Attaque des Titans Volume 2",
      author: "Hajime Isayama",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(title: "L'Attaque des Titans Volume 2 - Hajime Isayama EPUB", seeders: 50),
      request
    )

    assert_equal 100, score.breakdown[:title], score.breakdown.inspect
  end

  test "scores an abbreviated roman volume before a part label above the auto-select threshold" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    book = Book.create!(
      title: "Les Mis\u00E9rables Tome 5 Partie 1",
      author: "Victor Hugo",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "fr")
    score = ReleaseScorer.score(
      SearchResult.new(
        title: "Les Miserables T. V Partie 1 - Victor Hugo French EPUB",
        seeders: 50
      ),
      request
    )

    assert_equal 100, score.breakdown[:title], score.breakdown.inspect
    assert score.breakdown[:auto_select_allowed], score.breakdown.inspect
    assert_operator score.total, :>=, 90, "total #{score.total} breakdown #{score.breakdown.inspect}"
    assert score.high_confidence?, score.total.to_s
  end

  test "scores a terminal roman volume when the author is also inside the title" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    book = Book.create!(
      title: "The Collected Works of Carl Gustav Jung Volume I",
      author: "Carl Gustav Jung",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(
        title: "The Collected Works of Carl Gustav Jung Volume I - Carl Gustav Jung English EPUB",
        seeders: 50
      ),
      request
    )

    assert_equal 100, score.breakdown[:title], score.breakdown.inspect
    assert score.breakdown[:auto_select_allowed], score.breakdown.inspect
    assert_operator score.total, :>=, 90, "total #{score.total} breakdown #{score.breakdown.inspect}"
    assert score.high_confidence?, score.total.to_s
  end

  test "scores a roman volume followed by a novel subtitle above the auto-select threshold" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    book = Book.create!(title: "The Dark Tower Book V", author: "Stephen King", book_type: :ebook)
    request = Request.create!(book: book, user: @user, status: :pending, language: "en")
    score = ReleaseScorer.score(
      SearchResult.new(
        title: "The Dark Tower Book V A Novel - Stephen King English EPUB",
        seeders: 50
      ),
      request
    )

    assert_equal 100, score.breakdown[:title], score.breakdown.inspect
    assert score.breakdown[:auto_select_allowed], score.breakdown.inspect
    assert_operator score.total, :>=, 90, "total #{score.total} breakdown #{score.breakdown.inspect}"
    assert score.high_confidence?, score.total.to_s
  end

  test "scores an abbreviated roman volume before a language code above the auto-select threshold" do
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    book = Book.create!(
      title: "Les Mis\u00E9rables T. V",
      author: "Victor Hugo",
      book_type: :ebook
    )
    request = Request.create!(book: book, user: @user, status: :pending, language: "fr")
    score = ReleaseScorer.score(
      SearchResult.new(
        title: "Victor.Hugo.-.Les.Miserables.T.V.FR.EPUB",
        seeders: 50
      ),
      request
    )

    assert_equal 100, score.breakdown[:title], score.breakdown.inspect
    assert score.breakdown[:auto_select_allowed], score.breakdown.inspect
    assert_operator score.total, :>=, 90, "total #{score.total} breakdown #{score.breakdown.inspect}"
    assert score.high_confidence?, score.total.to_s
  end
end
