# frozen_string_literal: true

require "test_helper"

# End-to-end functional tests for the per-user directory routing feature.
#
# These tests exercise the full stack from the admin UI down to files on disk.
# They use real temp directories so every assertion is against actual filesystem
# state, not mocks.
#
# Two flows are covered:
#
#   Flow A — Already-acquired book
#     Admin configures routing → user requests a book already on disk →
#     RequestCreationService short-circuits → UserLibraryRoutingService runs →
#     file appears in user's personal directory.
#
#   Flow B — Download completion hook
#     Admin configures routing → download completes → PostProcessingJob calls
#     run_completion_side_effects → UserLibraryRoutingService runs → file
#     appears in user's personal directory.
#     (The Download/client infrastructure is not re-tested here; we drive the
#     exact method PostProcessingJob calls after a successful import.)
#
class DirectoryRoutingFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin = users(:two)
    @user  = users(:one)

    # Real temp directories — every assertion touches actual disk state
    @tmpdir     = Dir.mktmpdir("shelfarr_e2e_")
    @global_lib = File.join(@tmpdir, "audiobooks")
    @user_dir   = File.join(@tmpdir, "user_output")
    FileUtils.mkdir_p(@global_lib)

    sign_in_as(@admin)
  end

  teardown do
    FileUtils.rm_rf(@tmpdir)
  end

  # ── Flow A: Already-acquired book ─────────────────────────────────────────
  #
  # Steps exercised:
  #   1. Admin POSTs to update_directory_routing (real HTTP → controller → DB)
  #   2. RequestCreationService called for a book whose file_path is already set
  #   3. Service detects acquired book → calls after_create_for_acquired_book
  #   4. UserLibraryRoutingService copies files into @user_dir
  #   5. Request is immediately completed
  #   6. UserBookPath record exists

  test "already-acquired book: admin sets routing, request immediately routes file to user directory" do
    # ── Step 1: Admin configures routing via the real HTTP endpoint ──────────
    patch update_directory_routing_admin_user_url(@user), params: {
      user: { preferred_output_path: @user_dir, library_routing_mode: "copy" }
    }
    assert_redirected_to admin_users_path
    @user.reload
    assert_equal @user_dir, @user.preferred_output_path
    assert_equal "copy",    @user.library_routing_mode

    # ── Step 2: File already exists in the global library ───────────────────
    book = books(:audiobook_acquired)
    book_dir = File.join(@global_lib, "Test Author", "The Acquired Audiobook")
    FileUtils.mkdir_p(book_dir)
    File.write(File.join(book_dir, "chapter1.mp3"), "audio data")
    book.update!(file_path: book_dir)

    # ── Step 3: User creates a request — service detects file_path is set ───
    SettingsService.stub(:get, ->(*_args, **_kwargs) { @global_lib }) do
      result = RequestCreationService.call(
        user: @user,
        work_id: "openlibrary:OL_AUDIOBOOK_1",
        book_types: [ "audiobook" ],
        metadata_attrs: { title: book.title, author: book.author }
      )
      assert result.success?, result.errors.inspect
    end

    # ── Step 4: Request was completed immediately (no download queued) ───────
    request = @user.requests.find_by!(book: book)
    assert_equal "completed", request.status
    assert_no_enqueued_jobs only: SearchJob

    # ── Step 5: File appears in user's personal directory ───────────────────
    expected_file = File.join(@user_dir, "Test Author", "The Acquired Audiobook", "chapter1.mp3")
    assert File.exist?(expected_file),
      "Expected routed copy at #{expected_file}"
    assert_equal "audio data", File.read(expected_file)

    # ── Step 6: UserBookPath record links user to their copy ─────────────────
    record = UserBookPath.find_by(user: @user, book: book)
    assert_not_nil record
    assert record.file_path.start_with?(@user_dir)
  end

  test "already-acquired book: hardlink mode — user file shares inode with system copy" do
    patch update_directory_routing_admin_user_url(@user), params: {
      user: { preferred_output_path: @user_dir, library_routing_mode: "hardlink" }
    }
    assert_redirected_to admin_users_path
    @user.reload

    book = books(:audiobook_acquired)
    source_file = File.join(@global_lib, "book.m4b")
    File.write(source_file, "audiobook bytes")
    book.update!(file_path: source_file)

    SettingsService.stub(:get, ->(*_args, **_kwargs) { @global_lib }) do
      RequestCreationService.call(
        user: @user,
        work_id: "openlibrary:OL_AUDIOBOOK_1",
        book_types: [ "audiobook" ],
        metadata_attrs: { title: book.title, author: book.author }
      )
    end

    dest_file = File.join(@user_dir, "book.m4b")
    assert File.exist?(dest_file)
    assert_equal File.stat(source_file).ino, File.stat(dest_file).ino,
      "Hard link must share the same inode — no bytes duplicated on disk"
  end

  test "already-acquired book: no routing when user has no preferred_output_path configured" do
    # User has no routing config — system default only
    @user.update!(preferred_output_path: nil, library_routing_mode: nil)

    book = books(:audiobook_acquired)
    book_dir = File.join(@global_lib, "book_dir")
    FileUtils.mkdir_p(book_dir)
    File.write(File.join(book_dir, "track.mp3"), "audio")
    book.update!(file_path: book_dir)

    assert_no_difference "UserBookPath.count" do
      SettingsService.stub(:get, ->(*_args, **_kwargs) { @global_lib }) do
        RequestCreationService.call(
          user: @user,
          work_id: "openlibrary:OL_AUDIOBOOK_1",
          book_types: [ "audiobook" ],
          metadata_attrs: { title: book.title, author: book.author }
        )
      end
    end

    assert_equal 0, Dir.children(@tmpdir).count { |entry|
      File.directory?(File.join(@tmpdir, entry)) && entry != "audiobooks"
    }, "No user output directory should have been created"
  end

  # ── Flow B: Post-download routing via PostProcessingJob ───────────────────
  #
  # PostProcessingJob requires a fully set-up Download record and download
  # client state machine — wiring that belongs to existing download tests.
  # We drive run_completion_side_effects directly: it is the exact method
  # PostProcessingJob calls after a successful import, and it is where our
  # UserLibraryRoutingService hook lives.

  test "post-download: completion side effects route file to user directory" do
    @user.update!(preferred_output_path: @user_dir, library_routing_mode: "copy")

    # Simulate the state after PostProcessingJob has imported files to the
    # global library and set book.file_path
    book = books(:audiobook_acquired)
    book_dir = File.join(@global_lib, "Author", "Downloaded Book")
    FileUtils.mkdir_p(book_dir)
    File.write(File.join(book_dir, "part1.mp3"), "audio bytes")
    book.update!(file_path: book_dir)

    request = @user.requests.create!(book: book, status: :completed)

    # Drive the exact method PostProcessingJob calls after a successful import
    job = PostProcessingJob.new
    SettingsService.stub(:get, ->(*_args, **_kwargs) { @global_lib }) do
      job.send(:run_completion_side_effects, request, nil, book, book_dir)
    end

    expected = File.join(@user_dir, "Author", "Downloaded Book", "part1.mp3")
    assert File.exist?(expected),
      "Expected routed file at #{expected} after download completion"
    assert UserBookPath.exists?(user: @user, book: book)
  end

  test "post-download: hardlink mode — routed file shares inode with imported copy" do
    @user.update!(preferred_output_path: @user_dir, library_routing_mode: "hardlink")

    book = books(:audiobook_acquired)
    source = File.join(@global_lib, "book.epub")
    File.write(source, "epub content")
    book.update!(file_path: source)

    request = @user.requests.create!(book: book, status: :completed)

    job = PostProcessingJob.new
    SettingsService.stub(:get, ->(*_args, **_kwargs) { @global_lib }) do
      job.send(:run_completion_side_effects, request, nil, book, source)
    end

    dest = File.join(@user_dir, "book.epub")
    assert File.exist?(dest)
    assert_equal File.stat(source).ino, File.stat(dest).ino,
      "Hard link must share the same inode"
  end
end
