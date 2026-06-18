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
