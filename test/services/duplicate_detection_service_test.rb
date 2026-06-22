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
end
