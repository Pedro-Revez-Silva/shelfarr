# frozen_string_literal: true

require "test_helper"

class DuplicateDetectionServiceTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
  end

  test "allows request for new work" do
    result = DuplicateDetectionService.check(
      work_id: "OL_NEW_WORK",
      book_type: "audiobook"
    )

    assert result.allow?
    assert_nil result.message
    assert_nil result.existing_book
  end

  test "blocks request for same work+type already acquired" do
    book = Book.create!(
      title: "Existing Book",
      book_type: :audiobook,
      open_library_work_id: "OL_ACQUIRED",
      file_path: "/audiobooks/Author/Book"
    )

    result = DuplicateDetectionService.check(
      work_id: "OL_ACQUIRED",
      book_type: "audiobook"
    )

    assert result.block?
    assert_includes result.message, "already in your library"
    assert_equal book, result.existing_book
  end

  test "blocks request for same edition already acquired" do
    book = Book.create!(
      title: "Existing Book",
      book_type: :ebook,
      open_library_work_id: "OL_WORK",
      open_library_edition_id: "OL_EDITION",
      file_path: "/ebooks/Book.epub"
    )

    result = DuplicateDetectionService.check(
      work_id: "OL_WORK",
      edition_id: "OL_EDITION",
      book_type: "ebook"
    )

    assert result.block?
    assert_includes result.message, "exact edition"
    assert_equal book, result.existing_book
  end

  test "blocks request when active request exists" do
    book = Book.create!(
      title: "Pending Book",
      book_type: :audiobook,
      open_library_work_id: "OL_PENDING"
    )

    request = Request.create!(
      book: book,
      user: @user,
      status: :pending
    )

    result = DuplicateDetectionService.check(
      work_id: "OL_PENDING",
      book_type: "audiobook"
    )

    assert result.block?
    assert_includes result.message, "active request"
    assert_equal book, result.existing_book
    assert_equal request, result.existing_request
  end

  test "blocks request while the matching work is awaiting purchase" do
    book = Book.create!(
      title: "Store Offer Book",
      book_type: :ebook,
      open_library_work_id: "OL_AWAITING_PURCHASE"
    )
    request = Request.create!(
      book: book,
      user: @user,
      status: :awaiting_purchase
    )

    result = DuplicateDetectionService.check(
      work_id: "OL_AWAITING_PURCHASE",
      book_type: "ebook"
    )

    assert result.block?
    assert_includes result.message, "active request"
    assert_equal request, result.existing_request
  end

  test "reuses preloaded lookup for same and other book type checks" do
    book = Book.create!(
      title: "Existing Audiobook",
      book_type: :audiobook,
      google_books_id: "gb-preload"
    )
    lookup = Book.preload_by_work_ids([ "google_books:gb-preload" ])

    Book.stub(:preload_by_work_ids, ->(*) { raise "should not query again" }) do
      result = DuplicateDetectionService.check(
        work_id: "openlibrary:OL_PRELOAD_W",
        source_work_ids: [ "google_books:gb-preload" ],
        book_type: "ebook",
        existing_books_lookup: lookup
      )

      assert result.warn?
      assert_equal book, result.existing_book
    end
  end

  test "blocks request when any candidate source matches active request" do
    book = Book.create!(
      title: "Pending Google Book",
      book_type: :ebook,
      google_books_id: "gb-pending"
    )
    request = Request.create!(book: book, user: @user, status: :pending)

    result = DuplicateDetectionService.check(
      work_id: "openlibrary:OL_DIFFERENT_W",
      source_work_ids: [ "google_books:gb-pending" ],
      book_type: "ebook"
    )

    assert result.block?
    assert_includes result.message, "active request"
    assert_equal book, result.existing_book
    assert_equal request, result.existing_request
  end

  test "warns when same work exists as different type" do
    Book.create!(
      title: "Has Audiobook",
      book_type: :audiobook,
      open_library_work_id: "OL_BOTH",
      file_path: "/audiobooks/Author/Book"
    )

    result = DuplicateDetectionService.check(
      work_id: "OL_BOTH",
      book_type: "ebook"
    )

    assert result.warn?
    assert_includes result.message, "exists as an audiobook"
  end

  test "uses Comics & Manga in duplicate messages" do
    Book.create!(
      title: "Existing Graphic Title",
      book_type: :comicbook,
      content_kind: :graphic,
      comic_vine_id: "4000-duplicate-label"
    )

    result = DuplicateDetectionService.check(
      work_id: "comic_vine:4000-duplicate-label",
      book_type: "ebook"
    )

    assert result.warn?
    assert_includes result.message, "exists as a Comics & Manga title"
  end

  test "warns when previous request failed" do
    book = Book.create!(
      title: "Failed Book",
      book_type: :ebook,
      open_library_work_id: "OL_FAILED"
    )

    Request.create!(
      book: book,
      user: @user,
      status: :failed
    )

    result = DuplicateDetectionService.check(
      work_id: "OL_FAILED",
      book_type: "ebook"
    )

    assert result.warn?
    assert_includes result.message, "failed"
  end

  test "warns when previous request was not found" do
    book = Book.create!(
      title: "Not Found Book",
      book_type: :audiobook,
      open_library_work_id: "OL_NOT_FOUND"
    )

    Request.create!(
      book: book,
      user: @user,
      status: :not_found
    )

    result = DuplicateDetectionService.check(
      work_id: "OL_NOT_FOUND",
      book_type: "audiobook"
    )

    assert result.warn?
    assert_includes result.message, "not found"
  end

  test "can_request? returns true for allowed" do
    assert DuplicateDetectionService.can_request?(
      work_id: "OL_BRAND_NEW",
      book_type: "audiobook"
    )
  end

  test "can_request? returns true for warned" do
    Book.create!(
      title: "Audiobook Only",
      book_type: :audiobook,
      open_library_work_id: "OL_WARN",
      file_path: "/audiobooks/Author/Book"
    )

    assert DuplicateDetectionService.can_request?(
      work_id: "OL_WARN",
      book_type: "ebook"
    )
  end

  test "can_request? returns false for blocked" do
    Book.create!(
      title: "Acquired",
      book_type: :ebook,
      open_library_work_id: "OL_BLOCKED",
      file_path: "/ebooks/Book.epub"
    )

    refute DuplicateDetectionService.can_request?(
      work_id: "OL_BLOCKED",
      book_type: "ebook"
    )
  end

  test "blocks an acquired book when the candidate comes from another metadata provider" do
    book = Book.create!(
      title: "Project Hail Mary",
      author: "Andy Weir",
      book_type: :ebook,
      hardcover_id: "hc-hail-mary",
      file_path: "/ebooks/project-hail-mary.epub"
    )

    open_library = DuplicateDetectionService.check(
      work_id: "openlibrary:OL999001W",
      book_type: "ebook",
      title: "Project Hail Mary",
      author: "Weir, Andy"
    )
    google_books_editions = %w[gb-hail-mary-1 gb-hail-mary-2].map do |edition_id|
      DuplicateDetectionService.check(
        work_id: "google_books:#{edition_id}",
        book_type: "ebook",
        title: "Project Hail Mary: A Novel",
        author: "Andy Weir"
      )
    end

    assert open_library.block?, open_library.status.to_s
    assert_includes open_library.message, "already in your library"
    assert_equal book, open_library.existing_book
    google_books_editions.each do |result|
      assert result.block?, result.status.to_s
      assert_equal book, result.existing_book
    end
    refute DuplicateDetectionService.can_request?(
      work_id: "google_books:gb-hail-mary-3",
      book_type: "ebook",
      title: "Project Hail Mary",
      author: "Andy Weir"
    )
  end

  test "does not treat another format or a different work as the acquired copy" do
    Book.create!(
      title: "Dune",
      author: "Frank Herbert",
      book_type: :ebook,
      hardcover_id: "hc-dune",
      file_path: "/ebooks/dune.epub"
    )
    Book.create!(
      title: "Project Hail Mary",
      author: "Andy Weir",
      book_type: :audiobook,
      hardcover_id: "hc-hail-mary-audio",
      file_path: "/audiobooks/project-hail-mary"
    )
    Book.create!(
      title: "Saga - #1",
      author: "Brian K. Vaughan",
      book_type: :comicbook,
      content_kind: :graphic,
      hardcover_id: "hc-saga-1",
      file_path: "/comics/saga-1.cbz"
    )

    different_format = DuplicateDetectionService.check(
      work_id: "openlibrary:OL_HAIL_MARY_AUDIO_W",
      book_type: "ebook",
      title: "Project Hail Mary",
      author: "Andy Weir"
    )
    different_author = DuplicateDetectionService.check(
      work_id: "google_books:gb-dune-brian",
      book_type: "ebook",
      title: "Dune",
      author: "Brian Herbert"
    )
    sequel = DuplicateDetectionService.check(
      work_id: "google_books:gb-dune-messiah",
      book_type: "ebook",
      title: "Dune Messiah",
      author: "Frank Herbert"
    )
    other_subtitle = DuplicateDetectionService.check(
      work_id: "google_books:gb-dune-caladan",
      book_type: "ebook",
      title: "Dune: The Duke of Caladan",
      author: "Frank Herbert"
    )
    next_issue = DuplicateDetectionService.check(
      work_id: "comic_vine:4000-saga-2",
      book_type: "comicbook",
      title: "Saga - #2",
      author: "Brian K. Vaughan"
    )

    assert different_format.allow?
    assert different_author.allow?
    assert sequel.allow?
    assert other_subtitle.allow?
    assert next_issue.allow?
  end

  test "does not match an unacquired book by title and author" do
    Book.create!(
      title: "Project Hail Mary",
      author: "Andy Weir",
      book_type: :ebook,
      hardcover_id: "hc-hail-mary-pending"
    )

    result = DuplicateDetectionService.check(
      work_id: "openlibrary:OL_HAIL_MARY_PENDING_W",
      book_type: "ebook",
      title: "Project Hail Mary",
      author: "Andy Weir"
    )

    assert result.allow?
  end

  test "matches an illustrated edition and an inverted author name" do
    book = Book.create!(
      title: "The Hobbit",
      author: "J.R.R. Tolkien",
      book_type: :ebook,
      hardcover_id: "hc-hobbit",
      file_path: "/ebooks/the-hobbit.epub"
    )

    result = DuplicateDetectionService.check(
      work_id: "google_books:gb-hobbit-illustrated",
      book_type: "ebook",
      title: "The Hobbit (Illustrated Edition)",
      author: "Tolkien, J.R.R."
    )

    assert result.block?
    assert_equal book, result.existing_book
  end

  test "matches an inverted compound surname without dropping surname tokens" do
    book = Book.create!(
      title: "The Adventures of Sherlock Holmes",
      author: "Conan Doyle, Arthur",
      book_type: :ebook,
      open_library_work_id: "OL_STORED_DOYLE",
      file_path: "/ebooks/sherlock-holmes.epub"
    )

    natural = DuplicateDetectionService.check(
      work_id: "openlibrary:OL262421W",
      book_type: "ebook",
      title: "The Adventures of Sherlock Holmes",
      author: "Arthur Conan Doyle"
    )
    initial = DuplicateDetectionService.check(
      work_id: "google_books:gb-a-conan-doyle",
      book_type: "ebook",
      title: "The Adventures of Sherlock Holmes",
      author: "A. Conan Doyle"
    )
    shortened = DuplicateDetectionService.check(
      work_id: "google_books:gb-arthur-doyle",
      book_type: "ebook",
      title: "The Adventures of Sherlock Holmes",
      author: "Arthur Doyle"
    )

    assert natural.block?
    assert_equal book, natural.existing_book
    assert initial.block?
    assert_equal book, initial.existing_book
    assert shortened.allow?
  end

  test "matches a numbered anniversary edition and keeps sequence numbers distinct" do
    book = Book.create!(
      title: "The Hobbit: 75th Anniversary Edition",
      author: "J.R.R. Tolkien",
      book_type: :ebook,
      google_books_id: "zEK0ewyRMn4C",
      file_path: "/ebooks/the-hobbit-75th.epub"
    )

    anniversary = DuplicateDetectionService.check(
      work_id: "openlibrary:OL_HOBBIT_BASE_W",
      book_type: "ebook",
      title: "The Hobbit",
      author: "J.R.R. Tolkien"
    )
    numbered = DuplicateDetectionService.check(
      work_id: "openlibrary:OL_HOBBIT_BOOK_2_W",
      book_type: "ebook",
      title: "The Hobbit: Book 2",
      author: "J.R.R. Tolkien"
    )
    second_edition = DuplicateDetectionService.check(
      work_id: "google_books:gb-hobbit-2nd-edition",
      book_type: "ebook",
      title: "The Hobbit: 2nd Edition",
      author: "J.R.R. Tolkien"
    )

    assert anniversary.block?
    assert_equal book, anniversary.existing_book
    assert numbered.allow?
    assert second_edition.allow?
  end

  test "trusts a supplied empty lookup instead of querying per result" do
    Book.stub(:preload_by_work_ids, ->(*) { raise "should not query again" }) do
      result = DuplicateDetectionService.check(
        work_id: "openlibrary:OL_EMPTY_LOOKUP_W",
        book_type: "ebook",
        title: "Unknown Work",
        author: "Nobody In Particular",
        existing_books_lookup: {}
      )

      assert result.allow?
      assert_nil result.existing_book
    end
  end

  test "does not hard-block a shared surname when given names are missing or incompatible" do
    surname_only = Book.create!(
      title: "Selected Poems",
      author: "Browning",
      book_type: :ebook,
      hardcover_id: "hc-browning-surname",
      file_path: "/ebooks/browning-selected.epub"
    )
    initials = Book.create!(
      title: "Selected Poems",
      author: "E. B. Browning",
      book_type: :ebook,
      hardcover_id: "hc-eb-browning",
      file_path: "/ebooks/eb-browning-selected.epub"
    )
    Book.create!(
      title: "Dog Day Afternoon",
      author: "Al Pacino",
      book_type: :ebook,
      hardcover_id: "hc-al-pacino",
      file_path: "/ebooks/dog-day.epub"
    )

    robert = DuplicateDetectionService.check(
      work_id: "google_books:gb-robert-browning",
      book_type: "ebook",
      title: "Selected Poems",
      author: "Robert Browning"
    )
    surname = DuplicateDetectionService.check(
      work_id: "google_books:gb-browning-only",
      book_type: "ebook",
      title: "Selected Poems",
      author: "Browning"
    )
    same_initials = DuplicateDetectionService.check(
      work_id: "openlibrary:OL_EB_BROWNING_W",
      book_type: "ebook",
      title: "Selected Poems",
      author: "E.B. Browning"
    )
    expanded = DuplicateDetectionService.check(
      work_id: "google_books:gb-elizabeth-barrett",
      book_type: "ebook",
      title: "Selected Poems",
      author: "Elizabeth Barrett Browning"
    )
    other_pacino = DuplicateDetectionService.check(
      work_id: "google_books:gb-robert-pacino",
      book_type: "ebook",
      title: "Dog Day Afternoon",
      author: "Robert Pacino"
    )
    same_pacino = DuplicateDetectionService.check(
      work_id: "google_books:gb-al-pacino",
      book_type: "ebook",
      title: "Dog Day Afternoon",
      author: "Pacino, Al"
    )

    assert robert.allow?
    assert surname.allow?
    assert_equal initials, same_initials.existing_book
    assert_equal initials, expanded.existing_book
    assert other_pacino.allow?
    assert same_pacino.block?
    assert_not_equal surname_only, same_initials.existing_book
  end

  test "blocks an acquired copy whose title and author are not Latin script" do
    three_body = Book.create!(
      title: "三体",
      author: "刘慈欣",
      book_type: :ebook,
      hardcover_id: "hc-three-body",
      file_path: "/ebooks/three-body.epub"
    )
    crime = Book.create!(
      title: "Преступление и наказание",
      author: "Фёдор Достоевский",
      book_type: :ebook,
      hardcover_id: "hc-crime-punishment",
      file_path: "/ebooks/crime-and-punishment.epub"
    )
    onegin = Book.create!(
      title: "Евгений Онегин",
      author: "Александр Сергеевич Пушкин",
      book_type: :ebook,
      hardcover_id: "hc-onegin",
      file_path: "/ebooks/onegin.epub"
    )
    miserables = Book.create!(
      title: "Les Misérables",
      author: "Victor Hugo",
      book_type: :ebook,
      hardcover_id: "hc-miserables",
      file_path: "/ebooks/les-miserables.epub"
    )

    chinese = DuplicateDetectionService.check(
      work_id: "google_books:gb-three-body",
      book_type: "ebook",
      title: "三体",
      author: "刘慈欣"
    )
    other_chinese = DuplicateDetectionService.check(
      work_id: "google_books:gb-three-body-other",
      book_type: "ebook",
      title: "三体",
      author: "叶文洁"
    )
    russian = DuplicateDetectionService.check(
      work_id: "google_books:gb-crime-punishment",
      book_type: "ebook",
      title: "Преступление и наказание",
      author: "Федор Достоевский"
    )
    other_russian = DuplicateDetectionService.check(
      work_id: "google_books:gb-crime-other",
      book_type: "ebook",
      title: "Преступление и наказание",
      author: "Лев Толстой"
    )
    pushkin = DuplicateDetectionService.check(
      work_id: "google_books:gb-onegin",
      book_type: "ebook",
      title: "Евгений Онегин",
      author: "А. С. Пушкин"
    )
    accent = DuplicateDetectionService.check(
      work_id: "google_books:gb-miserables",
      book_type: "ebook",
      title: "Les Miserables",
      author: "Victor Hugo"
    )

    assert chinese.block?
    assert_equal three_body, chinese.existing_book
    assert other_chinese.allow?
    assert russian.block?
    assert_equal crime, russian.existing_book
    assert other_russian.allow?
    assert pushkin.block?
    assert_equal onegin, pushkin.existing_book
    assert accent.block?
    assert_equal miserables, accent.existing_book
  end

  test "normalizes acquired titles once per lookup and compares sequence markers only for that title" do
    Book.create!(
      title: "The Selected Poems",
      author: "Elizabeth Barrett Browning",
      book_type: :ebook,
      hardcover_id: "hc-selected-poems-index",
      file_path: "/ebooks/the-selected-poems.epub"
    )
    Book.create!(
      title: "Unrelated Atlas",
      author: "Ada Atlas",
      book_type: :ebook,
      hardcover_id: "hc-unrelated-atlas",
      file_path: "/ebooks/unrelated-atlas.epub"
    )
    lookup = {}
    title_calls = Hash.new(0)
    number_calls = Hash.new(0)

    count_calls(DuplicateDetectionService, :title_forms, title_calls) do
      count_calls(SequenceMarker, :numbers, number_calls) do
        2.times do |index|
          result = DuplicateDetectionService.check(
            work_id: "google_books:gb-selected-#{index}",
            book_type: "ebook",
            title: "Selected Poems",
            author: "Elizabeth Barrett Browning",
            existing_books_lookup: lookup
          )

          assert result.block?
        end
      end
    end

    assert_equal 1, title_calls["The Selected Poems"]
    assert_equal 1, title_calls["Unrelated Atlas"]
    assert_equal 2, title_calls["Selected Poems"]
    assert_equal 0, number_calls["Unrelated Atlas"]
    assert_equal 2, number_calls["The Selected Poems"]
    assert_equal 2, number_calls["Selected Poems"]
  end

  private

  def count_calls(object, method_name, calls)
    singleton = object.singleton_class
    original = singleton.instance_method(method_name)
    private_method = singleton.private_method_defined?(method_name)
    singleton.define_method(method_name) do |*args, **kwargs, &block|
      calls[args.first] += 1
      if kwargs.empty?
        original.bind_call(self, *args, &block)
      else
        original.bind_call(self, *args, **kwargs, &block)
      end
    end

    yield
  ensure
    singleton&.define_method(method_name, original) if original
    singleton&.send(:private, method_name) if private_method
  end
end
