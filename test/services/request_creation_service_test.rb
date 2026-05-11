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
end
