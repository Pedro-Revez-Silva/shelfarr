# frozen_string_literal: true

require "test_helper"

class BookTest < ActiveSupport::TestCase
  test "acquired scope only includes books with a usable path" do
    acquired = Book.create!(title: "Acquired", book_type: :ebook, file_path: "/books/acquired.epub")
    blank = Book.create!(title: "Blank", book_type: :ebook, file_path: "")
    whitespace = Book.create!(title: "Whitespace", book_type: :ebook, file_path: "  ")
    missing = Book.create!(title: "Missing", book_type: :ebook, file_path: nil)

    assert_includes Book.acquired, acquired
    assert_not_includes Book.acquired, blank
    assert_not_includes Book.acquired, whitespace
    assert_not_includes Book.acquired, missing
  end

  test "an acquisition reservation blocks another pipeline without entering the library scope" do
    book = Book.create!(
      title: "Reserved title",
      book_type: :ebook,
      acquisition_reservation_token: "reservation-token",
      acquisition_reservation_owner_type: "Download",
      acquisition_reservation_owner_id: 123
    )

    assert book.acquisition_reserved?
    assert book.acquisition_blocked?
    assert_not book.acquired?
    assert_not_includes Book.acquired, book
    assert_includes Book.pending, book
  end

  test "model destruction preserves Download and Upload acquisition reservations" do
    [ "Download", "Upload" ].each_with_index do |owner_type, index|
      book = Book.create!(
        title: "#{owner_type} reserved title",
        book_type: :ebook,
        acquisition_reservation_token: "#{owner_type.downcase}-reservation-token",
        acquisition_reservation_owner_type: owner_type,
        acquisition_reservation_owner_id: 1_000 + index
      )

      error = assert_raises(ActiveRecord::RecordNotDestroyed) { book.destroy! }

      assert_match(/acquisition.*recovery reservation/i, error.record.errors.full_messages.to_sentence)
      assert Book.exists?(book.id)
    end
  end

  test "model destruction preserves recoverable post-processing ownership" do
    book = Book.create!(title: "Post-processing recovery book", book_type: :ebook)
    request = Request.create!(
      book: book,
      user: users(:one),
      status: :processing
    )
    request.downloads.create!(
      name: book.title,
      status: :completed,
      post_processing_job_id: "post-processing-book-owner"
    )

    assert book.post_processing_recovery_pending?
    error = assert_raises(ActiveRecord::RecordNotDestroyed) { book.destroy! }

    assert_match(/post-processing/i, error.record.errors.full_messages.to_sentence)
    assert Book.exists?(book.id)
    assert Request.exists?(request.id)
  end

  test "model destruction preserves completed source cleanup state" do
    book = Book.create!(title: "Completed cleanup book", book_type: :ebook)
    request = Request.create!(
      book: book,
      user: users(:one),
      status: :completed
    )
    request.downloads.create!(
      name: book.title,
      status: :completed,
      post_processing_cleanup_state: '{"version":1}'
    )

    assert book.post_processing_recovery_pending?
    assert_raises(ActiveRecord::RecordNotDestroyed) { book.destroy! }
    assert Book.exists?(book.id)
    assert Request.exists?(request.id)
  end

  test "uses consolidated content kind values" do
    assert_equal({ "book" => 0, "graphic" => 1 }, Book.content_kinds)

    graphic_book = Book.new(title: "Graphic Novel", book_type: :comicbook, content_kind: :graphic)
    assert_equal "Comics & Manga", graphic_book.book_type_label
  end

  test "work_id helpers support google books ids" do
    book = Book.create!(
      title: "Test Book",
      book_type: :ebook,
      google_books_id: "abc123"
    )

    assert_equal "google_books:abc123", book.unified_work_id
    assert_equal book, Book.find_by_work_id("google_books:abc123", book_type: :ebook)

    initialized = Book.find_or_initialize_by_work_id("google_books:def456", book_type: :audiobook)

    assert initialized.new_record?
    assert_equal "def456", initialized.google_books_id
    assert_equal "audiobook", initialized.book_type
  end

  test "preload_by_work_ids returns books keyed by work id and book type" do
    audiobook = Book.create!(
      title: "Audio",
      book_type: :audiobook,
      google_books_id: "gb-audio"
    )
    ebook = Book.create!(
      title: "Ebook",
      book_type: :ebook,
      open_library_work_id: "OL123W"
    )

    lookup = Book.preload_by_work_ids([ "google_books:gb-audio", "openlibrary:OL123W" ])

    assert_equal audiobook, lookup.dig("google_books:gb-audio", "audiobook")
    assert_equal ebook, lookup.dig("openlibrary:OL123W", "ebook")
    assert_equal audiobook, Book.find_in_lookup(lookup, [ "google_books:gb-audio" ], book_type: :audiobook)
  end

  test "metadata source helpers expose provider label and url" do
    google_book = Book.new(title: "Google Book", book_type: :ebook, google_books_id: "abc123")
    open_library_book = Book.new(title: "Open Book", book_type: :ebook, open_library_work_id: "OL123W")
    hardcover_book = Book.new(title: "Hardcover Book", book_type: :ebook, hardcover_id: "789")

    assert_equal "Google Books", google_book.metadata_source_name
    assert_equal "https://books.google.com/books?id=abc123", google_book.metadata_source_url
    assert_equal "Metadata from Google Books", google_book.metadata_source_attribution
    assert_equal "Open Library", open_library_book.metadata_source_name
    assert_equal "https://openlibrary.org/works/OL123W", open_library_book.metadata_source_url
    assert_equal "Hardcover", hardcover_book.metadata_source_name
    assert_equal "https://hardcover.app/books/789", hardcover_book.metadata_source_url
  end


  test "model destruction preserves an Owned import which references its created book" do
    book = Book.create!(title: "Owned recovery book", book_type: :audiobook)
    connection = OwnedLibraryConnection.create!(enabled: true)
    item = connection.owned_library_items.create!(
      external_id: "B0BOOK#{SecureRandom.hex(3).upcase}",
      title: book.title,
      ownership_type: "purchased"
    )
    media_import = item.owned_media_imports.create!(
      status: "processing",
      created_book: book
    )

    error = assert_raises(ActiveRecord::RecordNotDestroyed) { book.destroy! }

    assert_match(/Audible backup.*recovery state/i, error.record.errors.full_messages.to_sentence)
    assert Book.exists?(book.id)
    assert_equal book, media_import.reload.created_book
  end
end
