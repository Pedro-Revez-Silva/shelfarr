# frozen_string_literal: true

require "test_helper"

class BookTest < ActiveSupport::TestCase
  test "unified_work_id returns googlebooks id when present" do
    book = Book.new(title: "T", book_type: :ebook, google_books_id: "vol1")
    assert_equal "googlebooks:vol1", book.unified_work_id
  end

  test "unified_work_id prefers hardcover over google books" do
    book = Book.new(title: "T", book_type: :ebook, hardcover_id: "hc1", google_books_id: "vol1")
    assert_equal "hardcover:hc1", book.unified_work_id
  end

  test "find_by_work_id finds book by googlebooks id" do
    book = Book.create!(title: "GB Book", book_type: :ebook, google_books_id: "vol1")
    found = Book.find_by_work_id("googlebooks:vol1", book_type: :ebook)
    assert_equal book, found
  end

  test "find_or_initialize_by_work_id sets google_books_id" do
    record = Book.find_or_initialize_by_work_id("googlebooks:vol42", book_type: :ebook)
    assert_equal "vol42", record.google_books_id
    assert record.new_record?
  end
end
