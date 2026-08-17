# frozen_string_literal: true

require "test_helper"

class UploadImportFileServiceTest < ActiveSupport::TestCase
  test "stages browser ingress privately and counts streamed bytes" do
    basename = "ingress-#{SecureRandom.hex(8)}.epub"
    source = StringIO.new("private purchased ebook")
    path, size = UploadImportFileService.stage_ingress!(source, basename, max_bytes: 1.megabyte)

    assert_equal "private purchased ebook".bytesize, size
    assert_equal "private purchased ebook", File.binread(path)
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(path)).mode & 0o777
  ensure
    FileUtils.rm_f(path) if path
  end

  test "browser ingress refuses a precreated symlink without changing its target" do
    basename = "ingress-link-#{SecureRandom.hex(8)}.epub"
    upload_directory = Rails.root.join("tmp", "uploads")
    FileUtils.mkdir_p(upload_directory)
    outside = Rails.root.join("tmp", "outside-#{SecureRandom.hex(8)}.txt")
    destination = upload_directory.join(basename)
    File.binwrite(outside, "keep me")
    File.symlink(outside, destination)

    assert_raises(UploadImportFileService::Error) do
      UploadImportFileService.stage_ingress!(StringIO.new("replace me"), basename, max_bytes: 1.megabyte)
    end
    assert_equal "keep me", File.binread(outside)
    assert File.symlink?(destination)
  ensure
    FileUtils.rm_f(destination) if destination
    FileUtils.rm_f(outside) if outside
  end

  test "browser ingress enforces its byte limit while streaming and removes partial bytes" do
    basename = "ingress-limit-#{SecureRandom.hex(8)}.epub"
    destination = Rails.root.join("tmp", "uploads", basename)

    assert_raises(UploadImportFileService::IngressTooLargeError) do
      UploadImportFileService.stage_ingress!(StringIO.new("too many bytes"), basename, max_bytes: 4)
    end
    assert_not File.exist?(destination)
  end

  test "discard ingress quarantines and removes the exact staged file" do
    basename = "ingress-discard-#{SecureRandom.hex(8)}.epub"
    path, = UploadImportFileService.stage_ingress!(
      StringIO.new("discard me"),
      basename,
      max_bytes: 1.megabyte
    )

    assert UploadImportFileService.discard_ingress!(path)
    assert_not File.exist?(path)
  ensure
    FileUtils.rm_f(path) if path
  end

  test "discard ingress never deletes a same-name replacement swapped before quarantine" do
    basename = "ingress-swap-#{SecureRandom.hex(8)}.epub"
    path, = UploadImportFileService.stage_ingress!(
      StringIO.new("original ingress"),
      basename,
      max_bytes: 1.megabyte
    )
    held_original = Rails.root.join("tmp", "uploads", ".held-#{SecureRandom.hex(8)}")
    original_rename = UploadImportFileService.method(:native_rename_noreplace)
    swapped = false
    interposed_rename = lambda do |source_fd, source_basename, destination_fd, destination_basename|
      if !swapped && source_basename == basename
        swapped = true
        File.rename(path, held_original)
        File.binwrite(path, "replacement ingress")
      end
      original_rename.call(source_fd, source_basename, destination_fd, destination_basename)
    end

    removed = UploadImportFileService.stub(:native_rename_noreplace, interposed_rename) do
      UploadImportFileService.discard_ingress!(path)
    end

    assert_not removed
    assert_equal "replacement ingress", File.binread(path)
    assert_equal "original ingress", File.binread(held_original)
  ensure
    FileUtils.rm_f(path) if path
    FileUtils.rm_f(held_original) if held_original
  end

  setup do
    @source_root = Dir.mktmpdir("ordinary-upload-source")
    @library_root = Dir.mktmpdir("ordinary-upload-library")
    @other_library_root = Dir.mktmpdir("ordinary-upload-other-library")
    SettingsService.set(:ebook_output_path, @library_root)
    @source = File.join(@source_root, "Author - Title.epub")
    File.binwrite(@source, "original ebook bytes")
    @upload = build_upload(@source)
    @book = Book.new(title: "Title", author: "Author", book_type: :ebook)
  end

  teardown do
    FileUtils.rm_rf(@source_root)
    FileUtils.rm_rf(@library_root)
    FileUtils.rm_rf(@other_library_root)
  end

  test "reserves a unique snapshotted path and atomically publishes verified bytes" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!

    copied_without_nested_transaction = false
    baseline_transactions = ActiveRecord::Base.connection.open_transactions
    original_publish = service.method(:publish_from_pinned_source!)
    guarded_publish = lambda do |**arguments|
      copied_without_nested_transaction =
        ActiveRecord::Base.connection.open_transactions == baseline_transactions
      original_publish.call(**arguments)
    end
    service.stub(:publish_from_pinned_source!, guarded_publish) do
      assert_equal service.book_library_path, service.publish!
    end

    destination = @upload.destination_path
    assert copied_without_nested_transaction
    assert_equal File.realpath(@library_root), @upload.destination_root
    assert_match(/\A[0-9a-f]{64}\z/, @upload.content_sha256)
    assert_equal "original ebook bytes", File.binread(destination)
    assert_equal 0o640, File.stat(destination).mode & 0o777
    assert File.exist?(@source), "the source remains until database completion"
  end

  test "a second active upload receives a distinct library reservation" do
    first = UploadImportFileService.new(upload: @upload, book: @book)
    first.reserve!
    second_source = File.join(@source_root, "second.epub")
    File.binwrite(second_source, "second ebook bytes")
    second_upload = build_upload(second_source)

    second = UploadImportFileService.new(upload: second_upload, book: @book)
    second.reserve!

    assert_not_equal @upload.reload.destination_path, second_upload.reload.destination_path
    assert_not_equal @upload.library_path, second_upload.library_path
    assert_match(/ \(2\)\z/, second_upload.library_path)
  end

  test "an active Audible reservation forces a distinct ordinary library path" do
    expected_library = File.join(File.realpath(@library_root), "Author", "Title")
    expected_destination = File.join(expected_library, "Author - Title.epub")
    connection = OwnedLibraryConnection.create!(enabled: true)
    item = connection.owned_library_items.create!(external_id: "B0CROSSPIPE", title: "Title")
    item.owned_media_imports.create!(
      status: "processing",
      library_path: expected_library,
      destination_path: expected_destination
    )

    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!

    assert_match(/Title \(2\)\z/, @upload.reload.library_path)
  end

  test "a settings change cannot redirect a persisted reservation" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    reserved_destination = @upload.reload.destination_path
    SettingsService.set(:ebook_output_path, @other_library_root)

    retried = UploadImportFileService.new(upload: @upload, book: @book)
    retried.reserve!
    retried.publish!

    assert_equal reserved_destination, @upload.reload.destination_path
    assert File.exist?(reserved_destination)
    assert_not reserved_destination.start_with?(File.realpath(@other_library_root))
  end

  test "a persisted reservation cannot be redirected into internal staging" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    internal_directory = File.join(
      File.realpath(@library_root),
      DirectDownloadFileService::STAGING_DIRECTORY,
      "Injected"
    )
    @upload.update_columns(
      destination_path: File.join(internal_directory, "book.epub"),
      library_path: internal_directory
    )

    assert_raises(UploadImportFileService::Error) { service.publish! }
    assert_not File.exist?(internal_directory)
  end

  test "destination-only recovery requires the persisted content digest" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    service.publish!
    destination = @upload.reload.destination_path
    File.unlink(@source)

    assert_equal destination, UploadImportFileService.recovery_source_path(@upload.reload)
    assert_not UploadImportFileService.restore_and_clear!(@upload)
    assert_equal "original ebook bytes", File.binread(destination)
    assert_not File.exist?(@source)
    assert_equal destination, @upload.reload.destination_path
  end

  test "rollback quarantines and removes a verified publication while preserving its source" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    service.publish!
    destination = @upload.reload.destination_path

    assert UploadImportFileService.restore_and_clear!(@upload)

    assert_not File.exist?(destination)
    assert_equal "original ebook bytes", File.binread(@source)
    assert_nil @upload.reload.destination_path
    assert_nil @upload.content_sha256
  end

  test "rollback retains a publication adopted as another Book's library directory" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    service.publish!
    destination = @upload.reload.destination_path
    adopted = Book.create!(
      title: "Adopted edition",
      author: "Another author",
      book_type: :ebook,
      file_path: @upload.library_path
    )

    assert_not UploadImportFileService.restore_and_clear!(@upload)
    assert_equal "original ebook bytes", File.binread(destination)
    assert_equal destination, @upload.reload.destination_path
    assert_equal @upload.library_path, adopted.reload.file_path
  end

  test "rollback never deletes a same-path replacement swapped before quarantine" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    service.publish!
    destination = @upload.reload.destination_path
    held_original = "#{destination}.held"
    original_rename = UploadImportFileService.method(:native_rename_noreplace)
    swapped = false
    interposed_rename = lambda do |source_fd, source_basename, destination_fd, destination_basename|
      if !swapped && source_basename == File.basename(destination)
        swapped = true
        File.rename(destination, held_original)
        File.binwrite(destination, "replacement library bytes")
      end
      original_rename.call(source_fd, source_basename, destination_fd, destination_basename)
    end

    restored = UploadImportFileService.stub(:native_rename_noreplace, interposed_rename) do
      UploadImportFileService.restore_and_clear!(@upload)
    end

    assert_not restored
    assert_equal "replacement library bytes", File.binread(destination)
    assert_equal "original ebook bytes", File.binread(held_original)
    assert_equal destination, @upload.reload.destination_path
  ensure
    FileUtils.rm_f(held_original) if held_original
  end

  test "same-size replacement is rejected and never deleted as this upload's file" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    destination = @upload.reload.destination_path
    FileUtils.mkdir_p(File.dirname(destination))
    replacement = "x" * File.size(@source)
    File.binwrite(destination, replacement)

    error = assert_raises(UploadImportFileService::Error) { service.publish! }

    assert_match(/became occupied|content changed/, error.message)
    assert_equal "original ebook bytes", File.binread(@source)
    assert UploadImportFileService.restore_and_clear!(@upload)
    assert_equal replacement, File.binread(destination)
    assert_nil @upload.reload.destination_path
  end

  test "a symbolic-link destination ancestor is rejected" do
    outside = Dir.mktmpdir("ordinary-upload-outside")
    File.symlink(outside, File.join(@library_root, "Author"))
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!

    error = assert_raises(UploadImportFileService::Error) { service.publish! }

    assert_match(/symbolic link/, error.message)
    assert_empty Dir.children(outside)
    assert File.exist?(@source)
  ensure
    FileUtils.rm_rf(outside) if outside
  end

  test "a raced symlink cannot redirect creation of a missing configured root" do
    configured_parent = Dir.mktmpdir("ordinary-configured-parent")
    outside = Dir.mktmpdir("ordinary-configured-outside")
    configured = File.join(configured_parent, "missing-library")
    SettingsService.set(:ebook_output_path, configured)
    original_mkdirat = FileCopyService.method(:native_mkdirat)
    interposed_mkdirat = lambda do |directory_fd, basename, mode|
      occupied = File.exist?(configured) || File.symlink?(configured)
      File.symlink(outside, configured) if basename == "missing-library" && !occupied
      original_mkdirat.call(directory_fd, basename, mode)
    end

    error = FileCopyService.stub(:native_mkdirat, interposed_mkdirat) do
      assert_raises(UploadImportFileService::Error) do
        UploadImportFileService.new(upload: @upload, book: @book)
      end
    end

    assert_match(/unsafe|accessible/, error.message)
    assert_empty Dir.children(outside)
  ensure
    FileUtils.rm_rf(configured_parent) if configured_parent
    FileUtils.rm_rf(outside) if outside
  end

  test "a destination parent swap during publication fails and retains its reservation" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    destination = Pathname(@upload.reload.destination_path)
    moved_parent = Pathname("#{destination.parent}-moved")
    outside = Pathname(Dir.mktmpdir("ordinary-upload-outside"))
    original_linkat = UploadImportFileService.method(:native_linkat)
    swapping_linkat = lambda do |*arguments|
      original_linkat.call(*arguments)
      File.rename(destination.parent, moved_parent)
      File.symlink(outside, destination.parent)
    end

    error = UploadImportFileService.stub(:native_rename_noreplace, false) do
      UploadImportFileService.stub(:native_linkat, swapping_linkat) do
        assert_raises(UploadImportFileService::AmbiguousPublicationError) { service.publish! }
      end
    end

    assert_match(/directory changed/, error.message)
    assert_empty Dir.children(outside)
    assert_equal "original ebook bytes", File.binread(moved_parent.join(destination.basename))
    assert File.exist?(@source)
    assert_not service.restore_and_clear!
    assert_equal destination.to_s, @upload.reload.destination_path
  ensure
    FileUtils.rm_rf(outside) if outside
    FileUtils.rm_rf(moved_parent) if moved_parent
  end

  test "an unreliable identity filesystem is never published by hardlink" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!

    error = FileCopyService.stub(:stable_hardlink_identity?, false) do
      UploadImportFileService.stub(:native_rename_noreplace, false) do
        UploadImportFileService.stub(:native_linkat, ->(*) { flunk "Unreliable identities must not use linkat" }) do
          assert_raises(UploadImportFileService::Error) { service.publish! }
        end
      end
    end

    assert_match(/stable hardlink identities/, error.message)
    assert File.exist?(@source)
  end

  test "a successful hardlink with an unusable destination retains an ambiguous reservation" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    destination = Pathname(@upload.reload.destination_path)
    real_link = UploadImportFileService.method(:native_linkat)
    real_open = UploadImportFileService.method(:native_openat)
    published = false
    opening = lambda do |directory_fd, basename, flags:, mode: 0|
      if published && basename == destination.basename.to_s
        raise Errno::EINVAL, "simulated CIFS reopen failure"
      end

      real_open.call(directory_fd, basename, flags: flags, mode: mode)
    end
    linking = lambda do |*arguments|
      real_link.call(*arguments).tap { published = true }
    end

    error = FileCopyService.stub(:stable_hardlink_identity?, true) do
      UploadImportFileService.stub(:native_rename_noreplace, false) do
        UploadImportFileService.stub(:native_linkat, linking) do
          UploadImportFileService.stub(:native_openat, opening) do
            FileCopyService.stub(:remove_pinned_child_if_identity, ->(*) { raise IOError, "cleanup failed" }) do
              assert_raises(UploadImportFileService::AmbiguousPublicationError) { service.publish! }
            end
          end
        end
      end
    end

    assert_match(/could not be verified after publication/, error.message)
    assert destination.exist?
    assert_not service.restore_and_clear!
    assert_equal destination.to_s, @upload.reload.destination_path
  end

  test "a retry retains an unverified private copy left after destination publication" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    service.publish!
    private_directory = File.join(
      File.realpath(@library_root),
      UploadImportFileService::PRIVATE_DIRECTORY,
      UploadImportFileService.send(:database_fingerprint)
    )
    FileUtils.mkdir_p(private_directory)
    private_copy = File.join(private_directory, "upload_#{@upload.id}.tmp")
    File.binwrite(private_copy, "original ebook bytes")

    assert_equal service.book_library_path, service.publish!
    assert_equal "original ebook bytes", File.binread(private_copy)
  end

  test "successful rename publication preserves a replacement at the consumed private path" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    private_directory = File.join(
      File.realpath(@library_root),
      UploadImportFileService::PRIVATE_DIRECTORY,
      UploadImportFileService.send(:database_fingerprint)
    )
    private_copy = nil
    real_rename = UploadImportFileService.method(:native_rename_noreplace)
    renaming = lambda do |*arguments|
      real_rename.call(*arguments).tap do |published|
        private_copy = File.join(private_directory, arguments.fetch(1))
        File.binwrite(private_copy, "replacement private bytes") if published
      end
    end

    UploadImportFileService.stub(:native_rename_noreplace, renaming) do
      service.publish!
    end
    service.publish!

    assert_equal "replacement private bytes", File.binread(private_copy)
    assert_equal "original ebook bytes", File.binread(@upload.reload.destination_path)
  end

  test "a crash-left private attempt does not block a retry" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    private_directory = File.join(
      File.realpath(@library_root),
      UploadImportFileService::PRIVATE_DIRECTORY,
      UploadImportFileService.send(:database_fingerprint)
    )
    FileUtils.mkdir_p(private_directory)
    stale_copy = File.join(private_directory, "upload_#{@upload.id}-#{"a" * 32}.tmp")
    File.binwrite(stale_copy, "crash-left bytes")

    service.publish!

    assert_equal "crash-left bytes", File.binread(stale_copy)
    assert_equal "original ebook bytes", File.binread(@upload.reload.destination_path)
  end

  test "a retry reclaims its owner-tagged private attempt on reliable filesystems" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    private_directory = File.join(
      File.realpath(@library_root),
      UploadImportFileService::PRIVATE_DIRECTORY,
      UploadImportFileService.send(:database_fingerprint)
    )
    FileUtils.mkdir_p(private_directory)
    stale_copy = File.join(
      private_directory,
      UploadImportFileService.send(:private_attempt_basename, @upload.id)
    )
    File.binwrite(stale_copy, "interrupted bytes")

    service.publish!

    assert_not File.exist?(stale_copy)
    assert_equal "original ebook bytes", File.binread(@upload.reload.destination_path)
  end

  test "a retry does not accumulate owner-tagged attempts when identities are unreliable" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    private_directory = File.join(
      File.realpath(@library_root),
      UploadImportFileService::PRIVATE_DIRECTORY,
      UploadImportFileService.send(:database_fingerprint)
    )
    FileUtils.mkdir_p(private_directory)
    stale_copy = File.join(
      private_directory,
      UploadImportFileService.send(:private_attempt_basename, @upload.id)
    )
    File.binwrite(stale_copy, "interrupted bytes")

    error = FileCopyService.stub(:stable_hardlink_identity?, false) do
      assert_raises(UploadImportFileService::Error) { service.publish! }
    end

    assert_match(/manual cleanup/, error.message)
    assert_equal [ File.basename(stale_copy) ], Dir.children(private_directory).grep(/\Aupload_/)
    assert_not File.exist?(@upload.reload.destination_path)
  end

  test "completed cleanup reconciles a source already truncated before its marker cleared" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    service.publish!
    @upload.update!(status: :completed)
    File.truncate(@source, 0)

    assert UploadImportFileService.cleanup_completed_source!(@upload)
    assert_nil @upload.reload.cleanup_source_path
    assert_equal 0, File.size(@source)
  end

  test "existing destination reconciliation validates its pinned parent" do
    service = UploadImportFileService.new(upload: @upload, book: @book)
    service.reserve!
    service.publish!
    destination = Pathname(@upload.reload.destination_path)
    moved_parent = Pathname("#{destination.parent}-moved-existing")
    outside = Pathname(Dir.mktmpdir("ordinary-existing-outside"))
    real_validation = UploadImportFileService.method(:validate_open_file!)
    swapped = false
    swapping_validation = lambda do |*arguments|
      result = real_validation.call(*arguments)
      unless swapped
        File.rename(destination.parent, moved_parent)
        File.symlink(outside, destination.parent)
        swapped = true
      end
      result
    end

    error = UploadImportFileService.stub(:validate_open_file!, swapping_validation) do
      assert_raises(UploadImportFileService::AmbiguousPublicationError) { service.publish! }
    end

    assert_match(/directory changed/, error.message)
    assert_empty Dir.children(outside)
    assert_equal "original ebook bytes", File.binread(moved_parent.join(destination.basename))
    assert_equal destination.to_s, @upload.reload.destination_path
  ensure
    FileUtils.rm_rf(outside) if outside
    FileUtils.rm_rf(moved_parent) if moved_parent
  end

  test "uses a bounded ordinary-upload lock namespace" do
    1_050.times do |index|
      UploadImportFileService.with_lock(@library_root, "upload-#{index}") { }
    end

    locks = Dir.glob(File.join(
      File.realpath(@library_root),
      UploadImportFileService::PRIVATE_DIRECTORY,
      UploadImportFileService.send(:database_fingerprint),
      UploadImportFileService::LOCKS_DIRECTORY,
      "lock-*"
    ))
    assert_operator locks.length, :<=, UploadImportFileService::LOCK_SHARDS
  end

  private

  def build_upload(path)
    Upload.create!(
      user: users(:two),
      original_filename: File.basename(path),
      file_path: path,
      file_size: File.size(path),
      book_type: :ebook,
      status: :processing
    )
  end
end
