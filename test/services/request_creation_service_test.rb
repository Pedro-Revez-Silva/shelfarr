# frozen_string_literal: true

require "test_helper"

class RequestCreationServiceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = users(:one)
    clear_enqueued_jobs
  end

  test "creates a request with fallback metadata" do
    assert_difference [ "Book.count", "Request.count" ], 1 do
      result = RequestCreationService.call(
        user: @user,
        work_id: "openlibrary:OL_SERVICE_123W",
        book_types: [ "ebook" ],
        metadata_attrs: {
          title: "Service Book",
          author: "Service Author",
          first_publish_year: 2024
        }
      )

      assert result.success?
      assert_empty result.errors
    end

    request = Request.last
    assert_equal @user, request.user
    assert_equal "Service Book", request.book.title
    assert_equal "Service Author", request.book.author
    assert_equal 2024, request.book.year
  end

  test "blocks duplicate active requests" do
    result = RequestCreationService.call(
      user: @user,
      work_id: "openlibrary:OL_EBOOK_1",
      book_types: [ "ebook" ],
      metadata_attrs: {
        title: "The Pending Ebook"
      }
    )

    assert_not result.success?
    assert_includes result.errors.join, "already has an active request"
  end

  test "enqueues search when auto approve applies to non-admin user" do
    SettingsService.set(:auto_approve_requests, true)

    assert_enqueued_with(job: SearchJob) do
      RequestCreationService.call(
        user: @user,
        work_id: "openlibrary:OL_AUTO_SERVICE_123W",
        book_types: [ "ebook" ],
        metadata_attrs: {
          title: "Auto Service Book"
        }
      )
    end
  end

  test "stores request origin metadata" do
    result = RequestCreationService.call(
      user: @user,
      work_id: "openlibrary:OL_ORIGIN_SERVICE_123W",
      book_types: [ "ebook" ],
      metadata_attrs: {
        title: "Origin Service Book"
      },
      origin: {
        created_via: "telegram",
        external_source: "telegram",
        external_user_id: "42",
        external_chat_id: "-100123"
      }
    )

    assert result.success?
    request = result.created_requests.first
    assert_equal "telegram", request.created_via
    assert_equal "telegram", request.external_source
    assert_equal "42", request.external_user_id
    assert_equal "-100123", request.external_chat_id
  end

  test "stores all candidate source identifiers on created book" do
    result = RequestCreationService.call(
      user: @user,
      work_id: "openlibrary:OL_MULTI_SOURCE_W",
      source_work_ids: [ "openlibrary:OL_MULTI_SOURCE_W", "google_books:gb-multi-source" ],
      book_types: [ "ebook" ],
      metadata_attrs: {
        title: "Multi Source Book",
        author: "Source Author"
      }
    )

    assert result.success?
    book = result.created_requests.first.book
    assert_equal "OL_MULTI_SOURCE_W", book.open_library_work_id
    assert_equal "gb-multi-source", book.google_books_id
  end

  test "persists newly assigned source ids on reused book with complete metadata" do
    book = Book.create!(
      title: "Existing Google Book",
      author: "Existing Author",
      book_type: :ebook,
      google_books_id: "gb-existing",
      year: 2020,
      description: "Known description",
      cover_url: "https://example.com/cover.jpg",
      metadata_source: "google_books"
    )

    result = RequestCreationService.call(
      user: @user,
      work_id: "openlibrary:OL_NEW_SOURCE_W",
      source_work_ids: [ "google_books:gb-existing", "hardcover:123" ],
      book_types: [ "ebook" ],
      metadata_attrs: {
        title: "Existing Google Book"
      }
    )

    assert result.success?
    book.reload
    assert_equal "gb-existing", book.google_books_id
    assert_equal "123", book.hardcover_id
    assert_equal "OL_NEW_SOURCE_W", book.open_library_work_id
  end

  test "reuses existing book matched only via alternate source identifier" do
    book = Book.create!(
      title: "Existing Google Book",
      book_type: :ebook,
      google_books_id: "gb-existing"
    )

    assert_no_difference "Book.count" do
      result = RequestCreationService.call(
        user: @user,
        work_id: "openlibrary:OL_NEW_SOURCE_W",
        source_work_ids: [ "google_books:gb-existing" ],
        book_types: [ "ebook" ],
        metadata_attrs: {
          title: "Existing Google Book"
        }
      )

      assert result.success?
      assert_equal book, result.created_requests.first.book
    end
  end

  test "blocks duplicate using alternate source identifier" do
    book = Book.create!(
      title: "Existing Google Book",
      book_type: :ebook,
      google_books_id: "gb-existing"
    )
    Request.create!(book: book, user: @user, status: :pending)

    result = RequestCreationService.call(
      user: @user,
      work_id: "openlibrary:OL_NEW_SOURCE_W",
      source_work_ids: [ "google_books:gb-existing" ],
      book_types: [ "ebook" ],
      metadata_attrs: {
        title: "Existing Google Book"
      }
    )

    assert_not result.success?
    assert_includes result.errors.join, "already has an active request"
  end
end
