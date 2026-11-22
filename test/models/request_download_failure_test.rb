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

  test "handle_download_failure keeps replace_library_file on the fallback download" do
    SettingsService.set(:auto_select_enabled, true)
    book = Book.create!(
      title: "Fallback Book",
      author: "Fallback Author",
      book_type: :ebook,
      file_path: "/ebooks/fallback-book.epub",
      open_library_work_id: SecureRandom.uuid
    )
    request = Request.create!(book: book, user: users(:one), status: :downloading, language: "en")
    selected = create_result(request, guid: "failed-replacement", status: :selected, seeders: 100)
    fallback = create_result(request, guid: "fallback-replacement", status: :rejected, seeders: 20)
    failed_download = request.downloads.create!(
      name: selected.title,
      search_result: selected,
      status: :failed,
      replace_library_file: true
    )

    assert_enqueued_with(job: DownloadJob) do
      request.handle_download_failure!(failed_download, reason: "Dead torrent")
    end

    assert fallback.reload.selected?
    retried = request.downloads.order(:id).last
    assert_equal fallback.id, retried.search_result_id
    assert retried.replace_library_file?
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

  test "blocklist_and_select_next cancels active downloads and selects the next candidate when auto-select is enabled" do
    SettingsService.set(:auto_select_enabled, true)
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
    assert request.reload.downloading?
    assert_not request.attention_needed?
  end

  test "blocklist_and_select_next blocklists and flags manual review when auto-select is disabled" do
    SettingsService.set(:auto_select_enabled, false)
    request = build_request
    selected = create_result(request, guid: "failed", status: :selected, seeders: 100)
    fallback = create_result(request, guid: "fallback", status: :rejected, seeders: 20)
    active_download = request.downloads.create!(name: selected.title, search_result: selected, status: :queued)

    outcome = nil
    assert_no_difference -> { request.downloads.count } do
      assert_no_enqueued_jobs only: DownloadJob do
        outcome = request.blocklist_and_select_next!(reason: "Blocklisted manually")
      end
    end

    assert_equal :manual_review, outcome
    assert active_download.reload.failed?
    assert selected.reload.blocklisted?
    assert fallback.reload.rejected?
    assert_includes request.reload.issue_description, "Select another release manually"
    assert_idle_attention_clears_downloading(request)
  end

  test "handle_download_failure does not fall back to the same info hash from another indexer" do
    SettingsService.set(:auto_select_enabled, true)
    request = build_request
    shared_hash = "a" * 40
    other_hash = "b" * 40
    selected = create_result(
      request,
      guid: "failed-indexer",
      status: :selected,
      seeders: 100,
      indexer: "FirstIndexer",
      magnet_url: "magnet:?xt=urn:btih:#{shared_hash}"
    )
    duplicate = create_result(
      request,
      guid: "other-indexer-same-torrent",
      status: :rejected,
      seeders: 90,
      indexer: "SecondIndexer",
      magnet_url: "magnet:?xt=urn:btih:#{shared_hash.upcase}&dn=Same+Book"
    )
    other = create_result(
      request,
      guid: "different-torrent",
      status: :rejected,
      seeders: 10,
      indexer: "ThirdIndexer",
      magnet_url: "magnet:?xt=urn:btih:#{other_hash}"
    )
    failed_download = request.downloads.create!(
      name: selected.title,
      search_result: selected,
      status: :failed,
      external_id: shared_hash,
      download_type: "torrent"
    )

    outcome = nil
    assert_difference -> { request.downloads.count }, 1 do
      assert_enqueued_with(job: DownloadJob) do
        outcome = request.handle_download_failure!(failed_download, reason: "Download not found in client")
      end
    end

    assert_equal :selected_next, outcome
    assert selected.reload.blocklisted?
    assert duplicate.reload.blocklisted?
    assert duplicate.rejected?
    assert other.reload.selected?
    assert_equal other.id, request.downloads.order(:id).last.search_result_id
    assert_not request.reload.attention_needed?
  end

  test "handle_download_failure skips a magnet matching the failed download info hash" do
    SettingsService.set(:auto_select_enabled, true)
    request = build_request
    shared_hash = "c" * 40
    other_hash = "d" * 40
    selected = create_result(
      request,
      guid: "torrent-url-release",
      status: :selected,
      seeders: 40,
      indexer: "FirstIndexer",
      magnet_url: nil,
      download_url: "http://prowlarr.example/1/download?id=1"
    )
    duplicate = create_result(
      request,
      guid: "magnet-copy",
      status: :rejected,
      seeders: 80,
      indexer: "SecondIndexer",
      magnet_url: "magnet:?xt=urn:btih:#{shared_hash}"
    )
    other = create_result(
      request,
      guid: "different-magnet",
      status: :rejected,
      seeders: 5,
      indexer: "ThirdIndexer",
      magnet_url: "magnet:?xt=urn:btih:#{other_hash}"
    )
    failed_download = request.downloads.create!(
      name: selected.title,
      search_result: selected,
      status: :failed,
      external_id: shared_hash.upcase,
      download_type: "torrent"
    )

    outcome = request.handle_download_failure!(failed_download, reason: "Download not found in client")

    assert_equal :selected_next, outcome
    assert duplicate.reload.blocklisted?
    assert other.reload.selected?
    assert_equal shared_hash, selected.reload.info_hash
  end

  test "handle_download_failure does not reselect the only remaining copy of a failed info hash" do
    SettingsService.set(:auto_select_enabled, true)
    request = build_request
    shared_hash = "e" * 40
    selected = create_result(
      request,
      guid: "failed-only",
      status: :selected,
      seeders: 20,
      magnet_url: "magnet:?xt=urn:btih:#{shared_hash}"
    )
    duplicate = create_result(
      request,
      guid: "same-hash-only-alternative",
      status: :rejected,
      seeders: 50,
      indexer: "OtherIndexer",
      magnet_url: "magnet:?xt=urn:btih:#{shared_hash}"
    )
    failed_download = request.downloads.create!(
      name: selected.title,
      search_result: selected,
      status: :failed,
      external_id: shared_hash,
      download_type: "torrent"
    )

    outcome = nil
    assert_no_difference -> { request.downloads.count } do
      assert_no_enqueued_jobs only: DownloadJob do
        outcome = request.handle_download_failure!(failed_download, reason: "Download not found in client")
      end
    end

    assert_equal :exhausted, outcome
    assert duplicate.reload.blocklisted?
    assert request.reload.not_found?
    assert request.attention_needed?
    assert_includes request.issue_description, "2 release(s) blocklisted"
  end

  test "handle_download_failure does not fall back to a stored info hash from another indexer" do
    SettingsService.set(:auto_select_enabled, true)
    request = build_request
    shared_hash = "9" * 40
    other_hash = "8" * 40
    selected = create_result(
      request,
      guid: "stored-hash",
      status: :selected,
      seeders: 30,
      magnet_url: nil,
      download_url: "http://indexer.example/a.torrent",
      info_hash: shared_hash
    )
    duplicate = create_result(
      request,
      guid: "stored-hash-copy",
      status: :rejected,
      seeders: 90,
      magnet_url: nil,
      download_url: "http://other.example/a.torrent",
      info_hash: shared_hash
    )
    other = create_result(
      request,
      guid: "stored-hash-other",
      status: :rejected,
      seeders: 4,
      magnet_url: "magnet:?xt=urn:btih:#{other_hash}"
    )
    failed_download = request.downloads.create!(
      name: selected.title,
      search_result: selected,
      status: :failed,
      external_id: "short-client-id",
      download_type: "torrent"
    )

    outcome = request.handle_download_failure!(failed_download, reason: "Download not found in client")

    assert_equal :selected_next, outcome
    assert duplicate.reload.blocklisted?
    assert other.reload.selected?
    assert_equal shared_hash, selected.reload.info_hash
  end

  test "blocklist_and_select_next does not select another indexer result with the same info hash" do
    SettingsService.set(:auto_select_enabled, true)
    request = build_request
    shared_hash = "f" * 40
    other_hash = "1" * 40
    selected = create_result(
      request,
      guid: "manual-block",
      status: :selected,
      seeders: 30,
      magnet_url: "magnet:?xt=urn:btih:#{shared_hash}"
    )
    duplicate = create_result(
      request,
      guid: "manual-block-copy",
      status: :pending,
      seeders: 70,
      magnet_url: "magnet:?xt=urn:btih:#{shared_hash}"
    )
    other = create_result(
      request,
      guid: "manual-block-other",
      status: :rejected,
      seeders: 4,
      magnet_url: "magnet:?xt=urn:btih:#{other_hash}"
    )
    request.downloads.create!(
      name: selected.title,
      search_result: selected,
      status: :downloading,
      external_id: shared_hash,
      download_type: "torrent"
    )

    outcome = nil
    assert_enqueued_with(job: DownloadJob) do
      outcome = request.blocklist_and_select_next!(reason: "Blocklisted manually")
    end

    assert_equal :selected_next, outcome
    assert selected.reload.blocklisted?
    assert duplicate.reload.blocklisted?
    assert duplicate.rejected?
    assert other.reload.selected?
  end

  test "blocklist_and_select_next returns no_selected_result without a selection" do
    SettingsService.set(:auto_select_enabled, true)
    request = build_request(status: :searching)

    assert_equal :no_selected_result, request.blocklist_and_select_next!(reason: "No selected release")
  end

  test "a failed info hash still blocks fallback after Refresh Search removes its release" do
    SettingsService.set(:auto_select_enabled, true)
    request = build_request
    failed_hash = "2" * 40
    other_hash = "3" * 40
    selected = create_result(
      request,
      guid: "opaque-url",
      status: :selected,
      seeders: 40,
      magnet_url: nil,
      download_url: "http://prowlarr.example/1/download?id=1"
    )
    failed_download = request.downloads.create!(
      name: selected.title,
      search_result: selected,
      status: :failed,
      external_id: failed_hash,
      download_type: "torrent"
    )

    assert_equal :exhausted, request.handle_download_failure!(failed_download, reason: "Download not found in client")

    request.refresh_search!
    assert_not SearchResult.exists?(selected.id)
    assert_nil failed_download.reload.search_result_id

    request.update!(status: :searching)
    same_torrent = create_result(request, guid: "fresh-copy", seeders: 100, magnet_url: "magnet:?xt=urn:btih:#{failed_hash}")
    other = create_result(request, guid: "fresh-other", seeders: 5, magnet_url: "magnet:?xt=urn:btih:#{other_hash}")

    assert AutoSelectService.call(request).success?

    assert other.reload.selected?
    assert same_torrent.reload.rejected?
  end

  test "a torrent cancelled by a manual switch stays a viable fallback" do
    SettingsService.set(:auto_select_enabled, false)
    request = build_request
    healthy_hash = "4" * 40
    replacement_hash = "5" * 40
    healthy = create_result(request, guid: "healthy", status: :selected, seeders: 50, magnet_url: "magnet:?xt=urn:btih:#{healthy_hash}")
    replacement = create_result(request, guid: "replacement", seeders: 10, magnet_url: "magnet:?xt=urn:btih:#{replacement_hash}")
    healthy_download = request.downloads.create!(
      name: healthy.title,
      search_result: healthy,
      status: :downloading,
      external_id: healthy_hash,
      download_type: "torrent"
    )

    replacement_download = request.select_result!(replacement)
    assert healthy_download.reload.failed?
    replacement_download.update!(status: :failed, external_id: replacement_hash, download_type: "torrent")

    assert_equal :manual_review, request.handle_download_failure!(replacement_download, reason: "Download not found in client")
    assert_nil healthy_download.reload.blocklisted_info_hash
    assert_equal replacement_hash, replacement_download.reload.blocklisted_info_hash

    request.refresh_search!
    SettingsService.set(:auto_select_enabled, true)
    request.update!(status: :searching)
    healthy_copy = create_result(request, guid: "healthy-copy", seeders: 5, magnet_url: "magnet:?xt=urn:btih:#{healthy_hash}")
    create_result(request, guid: "replacement-copy", seeders: 100, magnet_url: "magnet:?xt=urn:btih:#{replacement_hash}")

    assert AutoSelectService.call(request).success?
    assert healthy_copy.reload.selected?
  end

  test "manually selecting a release with a failed info hash overrides the stored failure" do
    SettingsService.set(:auto_select_enabled, false)
    request = build_request
    failed_hash = "6" * 40
    selected = create_result(request, guid: "failed", status: :selected, magnet_url: "magnet:?xt=urn:btih:#{failed_hash}")
    failed_download = request.downloads.create!(
      name: selected.title,
      search_result: selected,
      status: :failed,
      external_id: failed_hash,
      download_type: "torrent"
    )
    request.handle_download_failure!(failed_download, reason: "Download not found in client")
    request.refresh_search!
    request.update!(status: :searching)
    fresh_copy = create_result(request, guid: "fresh-copy", magnet_url: "magnet:?xt=urn:btih:#{failed_hash}")

    assert_difference -> { request.request_events.where(event_type: "blocklist_overridden").count }, 1 do
      request.select_result!(fresh_copy)
    end

    assert_nil failed_download.reload.blocklisted_info_hash
    assert_empty request.blocked_torrent_info_hashes
  end

  test "Refresh Search does not bring back a failed opaque release under the same GUID" do
    SettingsService.set(:auto_select_enabled, true)
    request = build_request
    opaque_url = "http://prowlarr.example/1/download?id=opaque"
    selected = create_result(request, guid: "opaque-guid", status: :selected, seeders: 40, magnet_url: nil, download_url: opaque_url)
    failed_download = request.downloads.create!(
      name: selected.title,
      search_result: selected,
      status: :failed,
      external_id: "7" * 40,
      download_type: "torrent"
    )
    request.handle_download_failure!(failed_download, reason: "Download not found in client")
    request.refresh_search!
    request.update!(status: :searching)

    returned_again = create_result(request, guid: "opaque-guid", seeders: 100, magnet_url: nil, download_url: opaque_url)
    other = create_result(request, guid: "other-guid", seeders: 5)

    assert AutoSelectService.call(request).success?
    assert other.reload.selected?
    assert_not returned_again.reload.selected?
  end

  test "the magnet that would be dispatched decides whether a result repeats a failed hash" do
    SettingsService.set(:auto_select_enabled, true)
    request = build_request
    failed_hash = "a" * 40
    selected = create_result(request, guid: "failed", status: :selected, seeders: 10, magnet_url: "magnet:?xt=urn:btih:#{failed_hash}")
    failed_download = request.downloads.create!(
      name: selected.title,
      search_result: selected,
      status: :failed,
      external_id: failed_hash,
      download_type: "torrent"
    )
    mislabelled = create_result(
      request,
      guid: "mislabelled",
      status: :rejected,
      seeders: 90,
      info_hash: "b" * 40,
      magnet_url: "magnet:?xt=urn:btih:#{failed_hash}"
    )
    other = create_result(request, guid: "other", status: :rejected, seeders: 5)

    assert_equal :selected_next, request.handle_download_failure!(failed_download, reason: "Download not found in client")

    assert other.reload.selected?
    assert mislabelled.reload.blocklisted?
  end

  test "overriding a migrated opaque release clears the hash recorded on its failed download" do
    SettingsService.set(:auto_select_enabled, false)
    request = build_request(status: :not_found)
    failed_hash = "c" * 40
    opaque = create_result(request, guid: "legacy-opaque", status: :rejected, magnet_url: nil, download_url: "http://indexer.example/legacy.torrent")
    opaque.blocklist!("Download not found in client")
    failed_download = request.downloads.create!(
      name: opaque.title,
      search_result: opaque,
      status: :failed,
      external_id: failed_hash,
      download_type: "torrent",
      blocklisted_info_hash: failed_hash
    )

    request.select_result!(opaque)

    assert_nil failed_download.reload.blocklisted_info_hash
    assert_empty request.blocked_torrent_info_hashes
  end

  test "manually selecting a failed GUID that now advertises another hash overrides the GUID failure" do
    SettingsService.set(:auto_select_enabled, false)
    request = build_request
    failed_hash = "8" * 40
    opaque_url = "http://prowlarr.example/1/download?id=opaque"
    selected = create_result(request, guid: "opaque-guid", status: :selected, magnet_url: nil, download_url: opaque_url)
    failed_download = request.downloads.create!(
      name: selected.title,
      search_result: selected,
      status: :failed,
      external_id: failed_hash,
      download_type: "torrent"
    )
    request.handle_download_failure!(failed_download, reason: "Download not found in client")
    request.refresh_search!
    request.update!(status: :searching)
    returned = create_result(request, guid: "opaque-guid", magnet_url: nil, download_url: opaque_url, info_hash: "9" * 40)

    request.select_result!(returned)

    assert_nil failed_download.reload.blocklisted_release_guid
    assert_empty request.blocked_release_guids
    assert_empty request.blocked_torrent_info_hashes
  end

  test "a republished GUID with a different torrent is judged by its hash, not its GUID" do
    SettingsService.set(:auto_select_enabled, true)
    request = build_request
    failed_hash = "d" * 40
    replacement_hash = "e" * 40
    selected = create_result(request, guid: "provider-guid", status: :selected, magnet_url: "magnet:?xt=urn:btih:#{failed_hash}")
    failed_download = request.downloads.create!(
      name: selected.title,
      search_result: selected,
      status: :failed,
      external_id: failed_hash,
      download_type: "torrent"
    )
    request.handle_download_failure!(failed_download, reason: "Download not found in client")
    request.refresh_search!
    request.update!(status: :searching)
    replacement = create_result(request, guid: "provider-guid", seeders: 50, magnet_url: "magnet:?xt=urn:btih:#{replacement_hash}")

    assert AutoSelectService.call(request).success?
    assert replacement.reload.selected?
    assert_equal [ failed_hash ], request.blocked_torrent_info_hashes
  end

  test "the hash the client reported replaces a stale advertised hash" do
    SettingsService.set(:auto_select_enabled, true)
    request = build_request
    reported_hash = "1" * 40
    advertised_hash = "2" * 40
    selected = create_result(
      request,
      guid: "stale-metadata",
      status: :selected,
      seeders: 40,
      magnet_url: nil,
      download_url: "http://indexer.example/stale.torrent",
      info_hash: advertised_hash
    )
    healthy = create_result(request, guid: "healthy", status: :rejected, seeders: 5, magnet_url: "magnet:?xt=urn:btih:#{advertised_hash}")
    failed_download = request.downloads.create!(
      name: selected.title,
      search_result: selected,
      status: :failed,
      external_id: reported_hash,
      download_type: "torrent"
    )

    assert_equal :selected_next, request.handle_download_failure!(failed_download, reason: "Download not found in client")

    assert healthy.reload.selected?
    assert_equal [ reported_hash ], request.blocked_torrent_info_hashes
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
