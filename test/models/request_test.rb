# frozen_string_literal: true

require "test_helper"

class RequestTest < ActiveSupport::TestCase
  test "adds awaiting purchase without renumbering existing statuses" do
    assert_equal({
      "pending" => 0,
      "searching" => 1,
      "not_found" => 2,
      "downloading" => 3,
      "processing" => 4,
      "completed" => 5,
      "failed" => 6,
      "awaiting_purchase" => 7
    }, Request.statuses)
  end

  test "treats awaiting purchase as open and retryable but not actively acquiring" do
    request = Request.create!(
      book: books(:ebook_pending),
      user: users(:one),
      status: :awaiting_purchase
    )

    assert request.open?
    assert request.can_retry?
    assert_includes Request.open, request
    assert_not request.active?
    assert_not_includes Request.active, request
  end

  test "search refresh is available only from non-acquisition request states" do
    Request::SEARCH_REFRESHABLE_STATUSES.each do |status|
      request = Request.create!(
        book: books(:ebook_pending),
        user: users(:one),
        status: status
      )

      assert request.search_refresh_allowed?, "expected #{status} to allow search refresh"
    end

    %w[downloading processing completed].each do |status|
      request = Request.create!(
        book: books(:ebook_pending),
        user: users(:one),
        status: status
      )

      assert_not request.search_refresh_allowed?, "expected #{status} to block search refresh"
      assert_raises(Request::SearchRefreshBlockedError) { request.refresh_search! }
    end
  end

  test "search refresh rechecks acquisition state under the transition lock" do
    request = Request.create!(
      book: books(:ebook_pending),
      user: users(:one),
      status: :pending
    )
    selected = request.search_results.create!(
      guid: "refresh-race-selected",
      title: "Refresh race selected release",
      magnet_url: "magnet:?xt=urn:btih:#{'a' * 40}",
      status: :selected
    )
    disposable = request.search_results.create!(
      guid: "refresh-race-disposable",
      title: "Refresh race disposable release",
      magnet_url: "magnet:?xt=urn:btih:#{'b' * 40}",
      status: :pending
    )
    stale_request = Request.find(request.id)
    download = request.downloads.create!(
      name: selected.title,
      search_result: selected,
      status: :queued
    )
    request.update!(status: :downloading)
    previous_generation = request.search_generation

    error = assert_raises(Request::SearchRefreshBlockedError) do
      stale_request.refresh_search!
    end

    assert_match(/acquisition.*active|awaiting recovery/i, error.message)
    assert request.reload.downloading?
    assert_equal previous_generation, request.search_generation
    assert SearchResult.exists?(selected.id)
    assert SearchResult.exists?(disposable.id)
    assert_equal selected, download.reload.search_result
  end

  test "search refresh preserves selected and manual results after safe admission" do
    request = Request.create!(
      book: books(:ebook_pending),
      user: users(:one),
      status: :not_found,
      attention_needed: true,
      issue_description: "Old search needs attention"
    )
    selected = request.search_results.create!(
      guid: "refresh-preserved-selected",
      title: "Preserved selected release",
      magnet_url: "magnet:?xt=urn:btih:#{'c' * 40}",
      status: :selected
    )
    manual = request.search_results.create!(
      guid: "manual-magnet:#{'d' * 40}",
      title: "Preserved manual release",
      magnet_url: "magnet:?xt=urn:btih:#{'d' * 40}",
      source: SearchResult::SOURCE_MANUAL_MAGNET,
      status: :pending
    )
    disposable = request.search_results.create!(
      guid: "refresh-removed-provider",
      title: "Removed provider release",
      magnet_url: "magnet:?xt=urn:btih:#{'e' * 40}",
      status: :pending
    )

    request.refresh_search!

    assert request.reload.pending?
    assert_not request.attention_needed?
    assert_nil request.issue_description
    assert SearchResult.exists?(selected.id)
    assert SearchResult.exists?(manual.id)
    assert_not SearchResult.exists?(disposable.id)
  end

  test "search refresh rejects upload and direct-download recovery from otherwise safe states" do
    upload_request = Request.create!(
      book: books(:ebook_pending),
      user: users(:one),
      status: :pending
    )
    Upload.create!(
      user: users(:one),
      request: upload_request,
      original_filename: "refresh-blocked.epub",
      file_path: "/tmp/refresh-blocked.epub",
      status: :pending
    )

    direct_request = Request.create!(
      book: books(:ebook_pending),
      user: users(:one),
      status: :failed
    )
    direct_request.downloads.create!(
      name: "Refresh direct recovery",
      status: :failed,
      direct_reservation_token: SecureRandom.hex(16)
    )

    assert_not upload_request.search_refresh_allowed?
    assert_not direct_request.search_refresh_allowed?
    assert_raises(Request::SearchRefreshBlockedError) { upload_request.refresh_search! }
    assert_raises(Request::SearchRefreshBlockedError) { direct_request.refresh_search! }
  end

  test "validates request scope" do
    request = Request.new(
      book: books(:ebook_pending),
      user: users(:one),
      status: :pending,
      request_scope: "invalid"
    )

    assert_not request.valid?
    assert_includes request.errors[:request_scope], "is not included in the list"
  end

  test "model destruction cannot cascade through a pending upload" do
    request = Request.create!(
      book: Book.create!(title: "Pending upload invariant", book_type: :ebook),
      user: users(:one),
      status: :pending
    )
    upload = Upload.create!(
      user: users(:one),
      request: request,
      original_filename: "pending.epub",
      file_path: "/tmp/pending-request-invariant.epub",
      status: :pending
    )

    error = assert_raises(ActiveRecord::RecordNotDestroyed) { request.destroy! }

    assert_match(/upload or Audible backup/i, error.record.errors.full_messages.to_sentence)
    assert Request.exists?(request.id)
    assert Upload.exists?(upload.id)
  end

  test "model destruction preserves Owned recovery state reached through its upload" do
    request = Request.create!(
      book: Book.create!(title: "Owned recovery invariant", book_type: :audiobook),
      user: users(:one),
      status: :failed
    )
    upload = Upload.create!(
      user: users(:one),
      request: request,
      original_filename: "owned.m4b",
      file_path: "/tmp/owned-request-invariant.m4b",
      status: :failed
    )
    connection = OwnedLibraryConnection.create!(enabled: true)
    item = connection.owned_library_items.create!(
      external_id: "B0REQUEST#{SecureRandom.hex(3).upcase}",
      title: "Owned recovery invariant",
      ownership_type: "purchased"
    )
    media_import = item.owned_media_imports.create!(
      request: request,
      upload: upload,
      requested_by: users(:one),
      status: "failed",
      destination_path: "/audiobooks/Owned recovery invariant.m4b",
      library_path: "/audiobooks/Owned recovery invariant.m4b",
      staged_device: 12,
      staged_inode: 34
    )

    assert_raises(ActiveRecord::RecordNotDestroyed) { request.destroy! }

    assert Request.exists?(request.id)
    assert Upload.exists?(upload.id)
    assert_equal request, media_import.reload.request
    assert_equal upload, media_import.upload
  end

  test "model destruction preserves an upload-owned Book reservation" do
    request = Request.create!(
      book: Book.create!(title: "Request upload reservation", book_type: :ebook),
      user: users(:one),
      status: :failed
    )
    upload = Upload.create!(
      user: users(:one),
      request: request,
      book: request.book,
      original_filename: "reserved.epub",
      file_path: "/tmp/request-upload-reservation.epub",
      status: :failed
    )
    token = SecureRandom.hex(16)
    upload.update!(book_reservation_token: token)
    request.book.update!(
      acquisition_reservation_token: token,
      acquisition_reservation_owner_type: "Upload",
      acquisition_reservation_owner_id: upload.id
    )

    assert request.upload_cancellation_blocked?
    assert_raises(ActiveRecord::RecordNotDestroyed) { request.destroy! }
    assert Request.exists?(request.id)
    assert Upload.exists?(upload.id)
    assert request.book.reload.acquisition_reserved?
  end

  test "model destruction cannot cascade through direct download recovery state" do
    request = Request.create!(
      book: Book.create!(title: "Direct recovery invariant", book_type: :ebook),
      user: users(:one),
      status: :failed
    )
    download = request.downloads.create!(
      name: "Direct recovery invariant",
      status: :failed,
      download_type: "direct",
      direct_staging_path: "/ebooks/.shelfarr-staging/direct-downloads/test/download"
    )

    error = assert_raises(ActiveRecord::RecordNotDestroyed) { request.destroy! }

    assert_match(/direct download awaiting safe recovery/i, error.record.errors.full_messages.to_sentence)
    assert Request.exists?(request.id)
    assert Download.exists?(download.id)
  end

  test "partial direct recovery metadata blocks cancellation and model destruction" do
    request = Request.create!(
      book: Book.create!(title: "Partial direct state", book_type: :ebook),
      user: users(:one),
      status: :failed
    )
    download = request.downloads.create!(
      name: "Partial direct state",
      status: :failed,
      direct_content_manifest: '["file",12,"digest"]'
    )

    assert request.direct_acquisition_recovery_pending?
    assert_not request.can_be_cancelled?
    assert_raises(ActiveRecord::RecordNotDestroyed) { request.destroy! }
    assert Download.exists?(download.id)
  end

  test "durable post-processing ownership blocks cancellation and destruction" do
    request = Request.create!(
      book: Book.create!(title: "Post-processing invariant", book_type: :ebook),
      user: users(:one),
      status: :processing
    )
    download = request.downloads.create!(
      name: "Post-processing invariant",
      status: :completed,
      post_processing_job_id: "durable-post-processing-owner"
    )

    assert request.post_processing_recovery_pending?
    assert_not request.can_be_cancelled?
    error = assert_raises(Request::CancellationBlockedError) { request.cancel! }
    destroyed = assert_raises(ActiveRecord::RecordNotDestroyed) { request.destroy! }

    assert_match(/post-processing recovery/i, error.message)
    assert_match(/post-processing/i, destroyed.record.errors.full_messages.to_sentence)
    assert Request.exists?(request.id)
    assert Download.exists?(download.id)
  end

  test "legacy owner IDs on completed requests are not treated as pending recovery" do
    request = Request.create!(
      book: Book.create!(title: "Legacy completed owner", book_type: :ebook),
      user: users(:one),
      status: :completed
    )
    request.downloads.create!(
      name: "Legacy completed owner",
      status: :completed,
      post_processing_job_id: "legacy-success-owner"
    )

    assert_not request.post_processing_recovery_pending?
    assert_nothing_raised { request.destroy! }
  end

  test "completed source cleanup state blocks request destruction" do
    request = Request.create!(
      book: Book.create!(title: "Completed cleanup", book_type: :ebook),
      user: users(:one),
      status: :completed
    )
    download = request.downloads.create!(
      name: "Completed cleanup",
      status: :completed,
      post_processing_cleanup_state: '{"version":1}'
    )

    assert request.post_processing_recovery_pending?
    assert_raises(ActiveRecord::RecordNotDestroyed) { request.destroy! }
    assert Request.exists?(request.id)
    assert Download.exists?(download.id)
  end

  test "cancel rechecks upload blockers after taking the transition lock" do
    request = Request.create!(
      book: Book.create!(title: "Cancel interleaving", book_type: :ebook),
      user: users(:one),
      status: :pending
    )
    upload = Upload.create!(
      user: users(:one),
      request: request,
      original_filename: "cancel-race.epub",
      file_path: "/tmp/cancel-race.epub",
      status: :pending
    )
    events = []
    original_lock = request.method(:serialize_acquisition_transition!)
    recorded_lock = lambda do
      events << :transition_lock
      original_lock.call
    end
    original_blocker = request.method(:upload_cancellation_blocked?)
    recorded_blocker = lambda do
      events << :blocker_check
      original_blocker.call
    end

    error = request.stub(:serialize_acquisition_transition!, recorded_lock) do
      request.stub(:upload_cancellation_blocked?, recorded_blocker) do
        assert_raises(Request::CancellationBlockedError) { request.cancel! }
      end
    end

    assert_equal [ :transition_lock, :blocker_check ], events
    assert_match(/upload.*in progress/i, error.message)
    assert request.reload.pending?
    assert upload.reload.pending?
  end

  test "direct recovery requires explicit preservation mode when recording cancellation" do
    request = Request.create!(
      book: Book.create!(title: "Direct cancellation transition", book_type: :ebook),
      user: users(:one),
      status: :downloading
    )
    download = request.downloads.create!(
      name: "Direct cancellation transition",
      status: :downloading,
      download_type: "direct",
      direct_staging_path: "/ebooks/.shelfarr-staging/direct-downloads/transition/download"
    )

    error = assert_raises(Request::CancellationBlockedError) { request.cancel! }
    assert_match(/direct download awaiting safe recovery/i, error.message)
    assert request.reload.downloading?
    assert download.reload.downloading?

    request.cancel!(allow_direct_recovery: true)

    assert request.reload.failed?
    assert download.reload.failed?
    assert_equal "/ebooks/.shelfarr-staging/direct-downloads/transition/download",
      download.direct_staging_path
  end

  test "cancel rechecks completed state after a stale cancellable preflight" do
    request = Request.create!(
      book: Book.create!(title: "Completion wins cancellation race", book_type: :ebook),
      user: users(:one),
      status: :pending
    )

    assert request.can_be_cancelled?

    request.complete!

    error = assert_raises(Request::CancellationBlockedError) { request.cancel! }

    assert_match(/completed status/i, error.message)
    assert request.reload.completed?
  end
end
