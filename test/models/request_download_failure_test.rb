# frozen_string_literal: true

require "test_helper"

class RequestDownloadFailureTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    SettingsService.set(:auto_select_confidence_threshold, 50)
    SettingsService.set(:auto_select_min_seeders, 1)
    SettingsService.set(:ebook_approved_formats, [])
    SettingsService.set(:ebook_rejected_formats, [])
    SettingsService.set(:ebook_preferred_formats, [])
    SettingsService.set(:preferred_download_types, %w[torrent usenet direct])
    clear_enqueued_jobs
  end

  test "handle_download_failure blocklists selected release and selects next candidate" do
    SettingsService.set(:auto_select_enabled, true)
    request = build_request
    selected = create_result(request, guid: "failed", status: :selected, seeders: 100)
    fallback = create_result(request, guid: "fallback", status: :rejected, seeders: 20)
    failed_download = request.downloads.create!(name: selected.title, search_result: selected, status: :failed)

    outcome = nil
    assert_difference -> { request.request_events.where(event_type: "release_blocklisted").count }, 1 do
      assert_difference -> { request.downloads.count }, 1 do
        assert_enqueued_with(job: DownloadJob) do
          outcome = request.handle_download_failure!(failed_download, reason: "Dead torrent")
        end
      end
    end

    assert_equal :selected_next, outcome
    assert selected.reload.blocklisted?
    assert selected.rejected?
    assert_equal "Dead torrent", selected.blocklist_reason
    assert fallback.reload.selected?
    assert request.reload.downloading?
    assert_not request.attention_needed?
  end

  test "handle_download_failure never reselects a blocklisted candidate" do
    SettingsService.set(:auto_select_enabled, true)
    request = build_request
    selected = create_result(request, guid: "failed", status: :selected, seeders: 100)
    blocklisted = create_result(request, guid: "blocked", status: :rejected, seeders: 90)
    blocklisted.blocklist!("Already failed")
    fallback = create_result(request, guid: "fallback", status: :rejected, seeders: 10)
    failed_download = request.downloads.create!(name: selected.title, search_result: selected, status: :failed)

    request.handle_download_failure!(failed_download, reason: "Rejected by client")

    assert blocklisted.reload.rejected?
    assert fallback.reload.selected?
  end

  test "handle_download_failure marks not_found when alternatives are exhausted" do
    SettingsService.set(:auto_select_enabled, true)
    request = build_request
    selected = create_result(request, guid: "failed", status: :selected, seeders: 100)
    blocked = create_result(request, guid: "blocked", status: :rejected, seeders: 20)
    blocked.blocklist!("Already failed")
    failed_download = request.downloads.create!(name: selected.title, search_result: selected, status: :failed)

    outcome = request.handle_download_failure!(failed_download, reason: "Dead torrent")

    assert_equal :exhausted, outcome
    assert request.reload.not_found?
    assert request.attention_needed?
    assert_includes request.issue_description, "2 release(s) blocklisted"
    assert_includes request.issue_description, "No suitable alternative"
  end

  test "handle_download_failure with auto-select disabled blocklists and flags manual review" do
    SettingsService.set(:auto_select_enabled, false)
    request = build_request
    selected = create_result(request, guid: "failed", status: :selected, seeders: 100)
    create_result(request, guid: "fallback", status: :rejected, seeders: 20)
    failed_download = request.downloads.create!(name: selected.title, search_result: selected, status: :failed)

    assert_no_difference -> { request.downloads.count } do
      outcome = request.handle_download_failure!(failed_download, reason: "Dead torrent")
      assert_equal :manual_review, outcome
    end

    assert selected.reload.blocklisted?
    assert_includes request.reload.issue_description, "Select another release manually"
    assert_idle_attention_clears_downloading(request)
  end

  test "handle_download_failure keeps downloading while another acquisition download is still active" do
    SettingsService.set(:auto_select_enabled, false)
    request = build_request
    selected = create_result(request, guid: "failed", status: :selected, seeders: 100)
    other = create_result(request, guid: "still-active", status: :pending, seeders: 20)
    failed_download = request.downloads.create!(name: selected.title, search_result: selected, status: :failed)
    request.downloads.create!(name: other.title, search_result: other, status: :queued)

    outcome = request.handle_download_failure!(failed_download, reason: "Dead torrent")

    assert_equal :manual_review, outcome
    assert request.reload.downloading?
    assert request.attention_needed?
    assert_not request.search_refresh_allowed?
    assert_includes Request.active, request
    assert DuplicateDetectionService.check(
      work_id: request.book.open_library_work_id,
      book_type: request.book.book_type
    ).block?
  end

  test "handle_download_failure keeps downloading while direct acquisition recovery remains" do
    SettingsService.set(:auto_select_enabled, false)
    request = build_request
    failed_download = request.downloads.create!(
      name: "Recoverable direct download", status: :failed, download_type: "direct",
      direct_staging_path: "/ebooks/.shelfarr-staging/direct-downloads/recovery/download"
    )

    assert_equal :manual_review, request.handle_download_failure!(failed_download, reason: "Cleanup could not finish")

    assert request.reload.downloading?
    assert request.attention_needed?
    assert_not request.search_refresh_allowed?
    assert DuplicateDetectionService.check(
      work_id: request.book.open_library_work_id, book_type: request.book.book_type
    ).block?
  end

  test "idle client failure keeps downloading while another import awaits recovery" do
    request = build_request
    request.downloads.create!(name: "Recoverable import", status: :completed, post_processing_job_id: "recovery-owner")

    request.mark_for_attention_after_idle_failure!("Client unavailable")

    assert request.reload.downloading?
    assert request.attention_needed?
    assert_not request.search_refresh_allowed?
  end

  test "handle_download_failure skips nil search result without crashing" do
    SettingsService.set(:auto_select_enabled, false)
    request = build_request
    failed_download = request.downloads.create!(name: "Legacy download", search_result: nil, status: :failed)

    outcome = request.handle_download_failure!(failed_download, reason: "Legacy failure")

    assert_equal :manual_review, outcome
    assert_equal 0, request.search_results.blocklisted.count
    assert_idle_attention_clears_downloading(request)
  end

  test "handle_download_failure is idempotent for an already blocklisted release" do
    SettingsService.set(:auto_select_enabled, false)
    request = build_request
    selected = create_result(request, guid: "failed", status: :selected, seeders: 100)
    failed_download = request.downloads.create!(name: selected.title, search_result: selected, status: :failed)

    request.handle_download_failure!(failed_download, reason: "First failure")

    assert_no_difference -> { request.request_events.where(event_type: "release_blocklisted").count } do
      request.handle_download_failure!(failed_download, reason: "Second failure")
    end

    assert_equal "First failure", selected.reload.blocklist_reason
    assert_idle_attention_clears_downloading(request)
  end

  test "blocklist_and_select_next cancels active downloads and runs selection even when auto-select is disabled" do
    SettingsService.set(:auto_select_enabled, false)
    request = build_request
    selected = create_result(request, guid: "failed", status: :selected, seeders: 100)
    fallback = create_result(request, guid: "fallback", status: :rejected, seeders: 20)
    active_download = request.downloads.create!(name: selected.title, search_result: selected, status: :queued)

    outcome = nil
    assert_difference -> { request.downloads.count }, 1 do
      assert_enqueued_with(job: DownloadJob) do
        outcome = request.blocklist_and_select_next!(reason: "Blocklisted manually")
      end
    end

    assert_equal :selected_next, outcome
    assert active_download.reload.failed?
    assert selected.reload.blocklisted?
    assert fallback.reload.selected?
  end

  test "blocklist_and_select_next returns no_selected_result without a selection" do
    SettingsService.set(:auto_select_enabled, true)
    request = build_request(status: :searching)

    assert_equal :no_selected_result, request.blocklist_and_select_next!(reason: "No selected release")
  end

  private

  def assert_idle_attention_clears_downloading(request)
    request.reload
    assert request.not_found?
    assert request.attention_needed?
    assert request.search_refresh_allowed?
    assert request.can_retry?
    assert_not_includes Request.active, request

    result = DuplicateDetectionService.check(
      work_id: request.book.open_library_work_id,
      book_type: request.book.book_type
    )
    assert result.warn?
    assert_includes result.message, "not found"
  end

  def build_request(status: :downloading)
    book = Book.create!(title: "Fallback Book", author: "Fallback Author", book_type: :ebook, open_library_work_id: SecureRandom.uuid)
    Request.create!(book: book, user: users(:one), status: status, language: "en")
  end

  def create_result(request, attrs)
    request.search_results.create!({
      guid: SecureRandom.uuid,
      title: "Fallback Book Fallback Author EPUB",
      indexer: "TestIndexer",
      status: :pending,
      confidence_score: 95,
      detected_language: "en",
      magnet_url: "magnet:?xt=urn:btih:#{SecureRandom.hex(20)}"
    }.merge(attrs))
  end
end
