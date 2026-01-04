# frozen_string_literal: true

require "test_helper"

class RequestRetryTest < ActiveSupport::TestCase
  setup do
    @pending = requests(:pending_request)
    @not_found_waiting = requests(:not_found_waiting)
    @max_retries_exceeded = requests(:max_retries_exceeded)
  end

  # === Scopes ===

  test "processable returns pending requests ordered by created_at" do
    # Create two pending requests with specific order
    older_book = Book.create!(title: "Older Processable", book_type: :ebook, open_library_work_id: "OL_OLDER_P")
    newer_book = Book.create!(title: "Newer Processable", book_type: :ebook, open_library_work_id: "OL_NEWER_P")

    older_request = Request.create!(book: older_book, user: users(:one), status: :pending, created_at: 2.days.ago)
    newer_request = Request.create!(book: newer_book, user: users(:one), status: :pending, created_at: 1.day.ago)

    processable = Request.processable
    older_index = processable.find_index(older_request)
    newer_index = processable.find_index(newer_request)

    assert older_index < newer_index, "Older request should come before newer request"
  end

  test "with_issues returns attention_needed and failed requests" do
    issues = Request.with_issues

    assert_includes issues, requests(:failed_request)
    assert_includes issues, requests(:max_retries_exceeded)
    assert_not_includes issues, requests(:pending_request)
    assert_not_includes issues, requests(:not_found_waiting)
  end

  test "retry_due returns not_found requests with past next_retry_at" do
    retry_due = Request.retry_due

    assert_includes retry_due, requests(:not_found_retry_due)
    assert_not_includes retry_due, requests(:not_found_waiting)
    assert_not_includes retry_due, requests(:pending_request)
  end

  # === schedule_retry! ===

  test "schedule_retry! sets not_found status with exponential backoff" do
    request = Request.create!(
      book: books(:ebook_pending),
      user: users(:one),
      status: :searching,
      retry_count: 0
    )

    base_delay_hours = SettingsService.get(:retry_base_delay_hours)

    freeze_time do
      result = request.schedule_retry!

      assert result
      assert request.not_found?
      assert_equal 1, request.retry_count
      assert_in_delta Time.current + base_delay_hours.hours, request.next_retry_at, 1.second
    end
  end

  test "schedule_retry! doubles delay with each retry" do
    base_delay_hours = SettingsService.get(:retry_base_delay_hours)

    # First retry: base_delay
    request1 = Request.create!(book: books(:ebook_pending), user: users(:one), status: :searching, retry_count: 0)
    freeze_time do
      request1.schedule_retry!
      assert_in_delta Time.current + base_delay_hours.hours, request1.next_retry_at, 1.second
    end

    # Second retry: base_delay * 2
    request2 = Request.create!(book: books(:audiobook_acquired), user: users(:one), status: :searching, retry_count: 1)
    freeze_time do
      request2.schedule_retry!
      expected_delay = base_delay_hours * 2
      assert_in_delta Time.current + expected_delay.hours, request2.next_retry_at, 1.second
    end
  end

  test "schedule_retry! caps delay at max_delay_days" do
    base_delay_hours = SettingsService.get(:retry_base_delay_hours)
    max_delay_days = SettingsService.get(:retry_max_delay_days)
    max_delay_hours = max_delay_days * 24

    # Calculate retry_count that would exceed max_delay without exceeding max_retries
    # Formula: base_delay * 2^retry_count > max_delay_hours
    # With base=24 and max=168 (7 days), retry_count=3 gives 24*8=192 > 168
    request = Request.create!(
      book: books(:ebook_pending),
      user: users(:one),
      status: :searching,
      retry_count: 3
    )

    freeze_time do
      request.schedule_retry!
      assert_in_delta Time.current + max_delay_hours.hours, request.next_retry_at, 1.second
    end
  end

  test "schedule_retry! flags attention when max_retries reached" do
    max_retries = SettingsService.get(:max_retries)

    request = Request.create!(
      book: books(:ebook_pending),
      user: users(:one),
      status: :searching,
      retry_count: max_retries
    )

    result = request.schedule_retry!

    assert_not result
    assert request.attention_needed?
    assert_includes request.issue_description, "Maximum retry attempts"
  end

  # === requeue! ===

  test "requeue! moves not_found back to pending" do
    request = requests(:not_found_retry_due)
    assert request.not_found?

    request.requeue!

    assert request.pending?
    assert_nil request.next_retry_at
  end

  # === retry_now! ===

  test "retry_now! resets request for immediate processing" do
    request = @max_retries_exceeded
    assert request.attention_needed?

    request.retry_now!

    assert request.pending?
    assert_nil request.next_retry_at
    assert_not request.attention_needed?
    assert_nil request.issue_description
  end

  # === cancel! ===

  test "cancel! marks request as failed" do
    request = @pending

    request.cancel!

    assert request.failed?
    assert_not request.attention_needed?
    assert_nil request.issue_description
  end

  # === can_retry? ===

  test "can_retry? returns true for pending, not_found, and failed" do
    assert @pending.can_retry?
    assert @not_found_waiting.can_retry?
    assert requests(:failed_request).can_retry?

    # Create a downloading request
    downloading = Request.create!(
      book: books(:audiobook_acquired),
      user: users(:one),
      status: :downloading
    )
    assert_not downloading.can_retry?
  end

  # === retry_due? ===

  test "retry_due? returns true when next_retry_at is past" do
    assert requests(:not_found_retry_due).retry_due?
    assert_not @not_found_waiting.retry_due?
    assert_not @pending.retry_due? # No next_retry_at
  end

  # === next_retry_in_words ===

  test "next_retry_in_words returns human-readable time" do
    request = Request.create!(
      book: books(:audiobook_acquired),
      user: users(:one),
      status: :not_found,
      next_retry_at: 30.minutes.from_now
    )

    assert_match(/minutes/, request.next_retry_in_words)

    request.update!(next_retry_at: 5.hours.from_now)
    assert_match(/hours/, request.next_retry_in_words)

    request.update!(next_retry_at: 3.days.from_now)
    assert_match(/days/, request.next_retry_in_words)
  end

  test "next_retry_in_words returns nil when no retry scheduled" do
    assert_nil @pending.next_retry_in_words
  end

  test "next_retry_in_words returns nil when retry is past" do
    assert_nil requests(:not_found_retry_due).next_retry_in_words
  end

  # === can_be_cancelled? ===

  test "can_be_cancelled? returns true for pending requests" do
    assert @pending.can_be_cancelled?
  end

  test "can_be_cancelled? returns true for searching requests" do
    searching = Request.create!(
      book: books(:ebook_pending),
      user: users(:one),
      status: :searching
    )
    assert searching.can_be_cancelled?
  end

  test "can_be_cancelled? returns true for not_found requests" do
    assert @not_found_waiting.can_be_cancelled?
  end

  test "can_be_cancelled? returns true for failed requests" do
    assert requests(:failed_request).can_be_cancelled?
  end

  test "can_be_cancelled? returns false for downloading requests" do
    downloading = Request.create!(
      book: books(:audiobook_acquired),
      user: users(:one),
      status: :downloading
    )
    assert_not downloading.can_be_cancelled?
  end

  test "can_be_cancelled? returns false for processing requests" do
    processing = Request.create!(
      book: books(:audiobook_acquired),
      user: users(:one),
      status: :processing
    )
    assert_not processing.can_be_cancelled?
  end

  test "can_be_cancelled? returns false for completed requests" do
    completed = Request.create!(
      book: books(:audiobook_acquired),
      user: users(:one),
      status: :completed
    )
    assert_not completed.can_be_cancelled?
  end
end
