# frozen_string_literal: true

require "test_helper"

class BookTest < ActiveSupport::TestCase
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
end
