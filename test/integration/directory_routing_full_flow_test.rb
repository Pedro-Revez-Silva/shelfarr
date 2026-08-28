# frozen_string_literal: true

require "test_helper"

# Functional end-to-end test for the per-user directory routing feature.
#
# Exercises the full request lifecycle without any shortcuts:
#
#   Admin sets routing → User submits request → SearchJob queries mock indexer →
#   Result saved → select_result! creates Download → DownloadJob dispatches to
#   mock qBittorrent → [download completes on disk] → PostProcessingJob imports
#   into system library → UserLibraryRoutingService routes to user directory
#
# Two external HTTP seams are stubbed — everything else is real:
#   • IndexerClient.search   — returns a synthetic IndexerClients::Result
#   • download_client.adapter — Minitest::Mock, expects add_torrent → hash
#
# File I/O uses real temp directories so every assertion is against actual
# disk state, not stubs.
#
# Why manual select_result! instead of AutoSelectService stub:
#   SearchJob calls attempt_auto_select only when auto_select_enabled is true.
#   Rather than thread a success-duck-type through the stub return value, we
#   let SearchJob save the result and exit, then call select_result! directly —
#   exactly what an admin or the auto-select service would do.
#
# Why DownloadJob.new.perform instead of perform_enqueued_jobs for DownloadJob:
#   select_result! enqueues DownloadJob via after_all_transactions_commit, which
#   does not fire inside the test wrapper transaction. We invoke perform directly.
#
class DirectoryRoutingFullFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin = users(:two)
    @user  = users(:one)

    @tmpdir   = Dir.mktmpdir("shelfarr_full_flow_")
    @dl_dir   = File.join(@tmpdir, "downloads")   # where the "downloader" writes files
    @lib_dir  = File.join(@tmpdir, "library")     # Shelfarr's system library
    @user_dir = File.join(@tmpdir, "user_output") # user's personal routed directory
    FileUtils.mkdir_p([@dl_dir, @lib_dir])

    sign_in_as(@admin)
  end

  teardown do
    FileUtils.rm_rf(@tmpdir)
  end

  # ── Copy mode ─────────────────────────────────────────────────────────────
  #
  # Full pipeline: indexer result → torrent dispatched → download complete →
  # post-processed into system library → duplicated into user directory.

  test "copy mode: file routed to user directory after full download pipeline" do
    # Step 1: Admin configures per-user routing via the real HTTP endpoint
    patch update_directory_routing_admin_user_url(@user), params: {
      user: { preferred_output_path: @user_dir, library_routing_mode: "copy" }
    }
    assert_redirected_to admin_users_path

    # Step 2: "qBittorrent" finishes downloading — files land on disk
    # (Simulates what the torrent client writes when a download completes)
    book_dl_dir = File.join(@dl_dir, "Test Author - The New Audiobook")
    FileUtils.mkdir_p(book_dl_dir)
    File.write(File.join(book_dl_dir, "chapter1.mp3"), "audio bytes")

    # Step 3: SearchJob + DownloadJob run with all external HTTP stubbed
    torrent_hash = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
    client, adapter = build_client_and_adapter(torrent_hash)

    download = run_search_and_dispatch(
      title: "The New Audiobook", author: "Test Author",
      work_id: "openlibrary:OL_FULL_FLOW_W",
      torrent_hash: torrent_hash, download_client: client, mock_adapter: adapter
    )

    adapter.verify  # confirms DownloadJob called add_torrent

    # Step 4: Simulate DownloadMonitorJob detecting the completed download
    # (The monitor polls qBittorrent's API and sets download_path when done.
    #  That's existing infrastructure — not our feature. We set the state directly.)
    assert_not_nil download, "DownloadJob should have created a Download record"
    download.update!(status: :completed, download_path: book_dl_dir)

    # Step 5: PostProcessingJob imports from dl_dir → lib_dir, then our hook
    # (UserLibraryRoutingService) copies lib_dir → user_dir
    run_post_processing(download)

    # ── Assertions ─────────────────────────────────────────────────────────
    book    = Book.find_by(title: "The New Audiobook")
    request = @user.requests.find_by(book: book)

    assert_not_nil book,    "Book record should be created by SearchJob"
    assert_not_nil request, "Request record should be created"
    assert_equal "completed", request.reload.status,
      "Request should be completed after PostProcessingJob"

    # System library: PostProcessingJob imports here
    assert book.reload.file_path.present?,
      "book.file_path should be set after import"
    assert File.exist?(File.join(book.file_path, "chapter1.mp3")),
      "chapter1.mp3 should be in the system library at #{book.file_path}"

    # User's personal directory: UserLibraryRoutingService routes here
    ubp = UserBookPath.find_by(user: @user, book: book)
    assert_not_nil ubp,
      "UserBookPath should be created by UserLibraryRoutingService"
    assert ubp.file_path.start_with?(@user_dir),
      "UserBookPath.file_path should be under #{@user_dir}"
    assert File.exist?(File.join(ubp.file_path, "chapter1.mp3")),
      "chapter1.mp3 should appear in the user's personal directory"
  end

  # ── Hardlink mode ─────────────────────────────────────────────────────────
  #
  # Same full pipeline, but routing creates a hard link instead of a copy.
  # The assertion is on inode identity — zero bytes duplicated.

  test "hardlink mode: user file shares inode with system library copy" do
    patch update_directory_routing_admin_user_url(@user), params: {
      user: { preferred_output_path: @user_dir, library_routing_mode: "hardlink" }
    }
    assert_redirected_to admin_users_path

    book_dl_dir = File.join(@dl_dir, "Test Author - Hardlink Book")
    FileUtils.mkdir_p(book_dl_dir)
    File.write(File.join(book_dl_dir, "track.mp3"), "audio bytes")

    torrent_hash = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3"
    client, adapter = build_client_and_adapter(torrent_hash)

    download = run_search_and_dispatch(
      title: "Hardlink Book", author: "Test Author",
      work_id: "openlibrary:OL_HARDLINK_FLOW_W",
      torrent_hash: torrent_hash, download_client: client, mock_adapter: adapter
    )
    adapter.verify

    download.update!(status: :completed, download_path: book_dl_dir)
    run_post_processing(download)

    book = Book.find_by(title: "Hardlink Book")
    ubp  = UserBookPath.find_by(user: @user, book: book)
    assert_not_nil ubp

    lib_file  = File.join(book.file_path, "track.mp3")
    user_file = File.join(ubp.file_path,  "track.mp3")

    assert File.exist?(lib_file),  "track.mp3 should be in system library"
    assert File.exist?(user_file), "track.mp3 should be in user directory"
    assert_equal File.stat(lib_file).ino, File.stat(user_file).ino,
      "Hard link must share the same inode as the library copy — no bytes duplicated"
  end

  # ── No routing when user has no config ────────────────────────────────────
  #
  # Full pipeline still runs; PostProcessingJob still imports to system library.
  # UserLibraryRoutingService is a no-op when preferred_output_path is nil.

  test "no routing when user has no preferred_output_path configured" do
    @user.update!(preferred_output_path: nil, library_routing_mode: nil)

    book_dl_dir = File.join(@dl_dir, "Test Author - Unrouted Book")
    FileUtils.mkdir_p(book_dl_dir)
    File.write(File.join(book_dl_dir, "audio.mp3"), "audio bytes")

    torrent_hash = "c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
    client, adapter = build_client_and_adapter(torrent_hash)

    download = run_search_and_dispatch(
      title: "Unrouted Book", author: "Test Author",
      work_id: "openlibrary:OL_UNROUTED_FLOW_W",
      torrent_hash: torrent_hash, download_client: client, mock_adapter: adapter
    )
    adapter.verify

    download.update!(status: :completed, download_path: book_dl_dir)

    assert_no_difference "UserBookPath.count" do
      run_post_processing(download)
    end

    book = Book.find_by(title: "Unrouted Book")
    assert book.reload.file_path.present?,
      "System library import should still happen even without user routing"
    assert_not Dir.exist?(@user_dir),
      "No user output directory should be created when routing is not configured"
  end

  private

  # Creates a real DownloadClient AR record and a Minitest::Mock adapter.
  # The mock expects exactly one call to add_torrent and returns torrent_hash.
  def build_client_and_adapter(torrent_hash)
    client = DownloadClient.create!(
      name:        "Test qBittorrent #{torrent_hash[0, 6]}",
      client_type: :qbittorrent,
      url:         "http://localhost:9999"
    )
    adapter = Minitest::Mock.new
    adapter.expect(:add_torrent, torrent_hash, [String])
    [client, adapter]
  end

  # Runs the full SearchJob → select_result! → DownloadJob pipeline.
  #
  # Phase 1 — SearchJob queries the mock indexer and saves the result to the DB.
  #   auto_select_enabled is absent from the settings stub (defaults false),
  #   so attempt_auto_select exits early. We select the result manually below,
  #   which is exactly what AutoSelectService or the admin UI does.
  #
  # Phase 2 — select_result! creates the Download record.
  #
  # Phase 3 — DownloadJob dispatches to the mock qBittorrent adapter.
  #   after_all_transactions_commit (which normally enqueues DownloadJob after
  #   select_result!) does not fire inside the test wrapper transaction, so we
  #   call DownloadJob#perform directly.
  #
  # Returns the Download record so the caller can update it and run PostProcessingJob.
  def run_search_and_dispatch(title:, author:, work_id:, torrent_hash:, download_client:, mock_adapter:)
    fake_result = IndexerClients::Result.new(
      guid:         "test-guid-#{torrent_hash[0, 8]}",
      title:        "#{author} - #{title}",
      indexer:      "FakeIndexer",
      size_bytes:   1_000_000,
      seeders:      50,
      leechers:     5,
      download_url: "http://indexer.local/#{torrent_hash}.torrent",
      magnet_url:   nil,
      info_url:     nil,
      published_at: 1.day.ago,
      category_ids: [3030]
    )

    # Phase 1: SearchJob finds the mock indexer result and saves it.
    with_test_settings do
      IndexerClient.stub(:configured?, true) do
        IndexerClient.stub(:provider, "prowlarr") do
          IndexerClient.stub(:search, [fake_result]) do
            perform_enqueued_jobs(only: SearchJob) do
              RequestCreationService.call(
                user:           @user,
                work_id:        work_id,
                book_types:     ["audiobook"],
                metadata_attrs: { title: title, author: author }
              )
            end
          end
        end
      end
    end

    # Phase 2: Select the search result — mirrors what AutoSelectService or an
    # admin does after seeing search results in the UI.
    request       = @user.requests.reload.last
    search_result = request.search_results.reload.first
    assert_not_nil search_result,
      "SearchJob should have saved a SearchResult via the mock indexer"

    request.select_result!(search_result)
    download = request.downloads.reload.last
    assert_not_nil download, "select_result! should have created a Download record"

    # Phase 3: DownloadJob dispatches to the mock qBittorrent adapter.
    with_test_settings do
      DownloadClientSelector.stub(:for_download, download_client) do
        download_client.stub(:adapter, mock_adapter) do
          DownloadJob.new.perform(download.id)
        end
      end
    end

    download
  end

  # Runs PostProcessingJob for real.
  # Imports files from download_path → @lib_dir (system library), then
  # run_completion_side_effects calls UserLibraryRoutingService → @user_dir.
  def run_post_processing(download)
    with_test_settings do
      LibraryPlatformClient.stub(:configured?, false) do
        perform_enqueued_jobs(only: PostProcessingJob) do
          PostProcessingJob.perform_later(download.id)
        end
      end
    end
  end

  # Stubs SettingsService.get for all keys the pipeline reads.
  # Without this, calls would hit the DB where test rows may not exist,
  # causing jobs to fall back to production paths like /audiobooks or /downloads.
  #
  # Note: auto_select_enabled is intentionally absent (defaults to false).
  # SearchJob will save results and mark for manual selection, which is the
  # correct setup for Phase 2's explicit select_result! call.
  def with_test_settings(&block)
    settings = {
      audiobook_output_path:               @lib_dir,
      ebook_output_path:                   @lib_dir,
      comicbook_output_path:               @lib_dir,
      download_local_path:                 @dl_dir,
      completed_download_import_mode:      "copy",
      auto_approve_requests:               true,
      post_processing_source_path_retries: 0,
      download_check_interval:             1,
      split_audiobook_bundle_imports:      false,
      min_match_confidence:                0
    }
    SettingsService.stub(:get, ->(key, **opts) { settings.fetch(key, opts[:default]) }, &block)
  end
end
