# frozen_string_literal: true

require "test_helper"
require "digest"
require "tempfile"

class DirectDownloadFileServiceTest < ActiveSupport::TestCase
  setup do
    @output_root = Dir.mktmpdir
    @book = Book.create!(title: "Direct Recovery", author: "Safety Author", book_type: :ebook)
    @request = Request.create!(book: @book, user: users(:one), status: :downloading)
    @download = @request.downloads.create!(
      name: "Direct Recovery",
      status: :downloading,
      download_type: "direct"
    )
    @destination = File.join(@output_root, "Safety Author", "Direct Recovery", "book.epub")
    @service = build_service
  end

  teardown do
    FileUtils.rm_rf(@output_root)
  end

  test "publishes a file outside a database transaction while a durable Book reservation is visible" do
    staging = @service.create_staging!
    observed_transaction = nil
    observed_reservation = nil
    baseline_transactions = ActiveRecord::Base.connection.open_transactions
    original_copy = FileCopyService.method(:cp_io_noreplace)

    Tempfile.create([ "book-", ".epub" ], staging) do |source|
      source.binmode
      source.write("PK\x03\x04complete ebook")
      source.flush
      source.fsync

      FileCopyService.stub(:cp_io_noreplace, lambda { |io, destination, root:, heartbeat: nil|
        observed_transaction = ActiveRecord::Base.connection.open_transactions
        observed_reservation = @book.reload.acquisition_reserved?
        original_copy.call(io, destination, root: root, heartbeat: heartbeat)
      }) do
        assert @service.publish_file_and_finalize!(source)
      end
    end

    assert_equal baseline_transactions, observed_transaction
    assert observed_reservation
    assert_equal File.dirname(@destination), @book.reload.file_path
    assert @download.reload.completed?
    assert @request.reload.completed?
    assert_equal "PK\x03\x04complete ebook", File.binread(@destination)
    assert_equal 0o640, File.stat(@destination).mode & 0o777
    assert @service.cleanup_after_run!
    assert_nil @download.reload.direct_staging_path
  end

  test "an interrupted publication retains ownership until recovery safely removes staging" do
    staging = @service.create_staging!

    Tempfile.create([ "book-", ".epub" ], staging) do |source|
      source.write("PK\x03\x04complete ebook")
      source.flush

      FileCopyService.stub(:cp_io_noreplace, ->(*) { raise IOError, "interrupted publication" }) do
        assert_raises(IOError) { @service.publish_file_and_finalize!(source) }
      end
    end

    assert @book.reload.acquisition_reserved?
    assert_nil @book.file_path
    assert_not File.exist?(@destination)
    assert_not @service.cleanup_after_run!
    @download.update_columns(status: Download.statuses[:failed], updated_at: 1.hour.ago)
    assert_not DirectDownloadFileService.reconcile!(@download)
    assert_not @book.reload.acquisition_reserved?
    assert_nil @download.reload.direct_staging_path
  end

  test "a conflicting file is preserved and does not strand a reservation" do
    staging = @service.create_staging!
    FileUtils.mkdir_p(File.dirname(@destination))
    File.binwrite(@destination, "winner bytes")

    Tempfile.create([ "book-", ".epub" ], staging) do |source|
      source.write("PK\x03\x04replacement")
      source.flush

      assert_raises DirectDownloadFileService::ConflictError do
        @service.publish_file_and_finalize!(source)
      end
    end

    assert_equal "winner bytes", File.binread(@destination)
    assert_not @book.reload.acquisition_reserved?
    assert_nil @book.file_path
    assert @service.cleanup_after_run!
  end

  test "file publication under a replaced output root never completes the Book" do
    staging = @service.create_staging!
    displaced_root = "#{@output_root}-original"
    original_copy = FileCopyService.method(:cp_io_noreplace)
    swap_then_copy = lambda do |source, destination, root:, heartbeat: nil|
      File.rename(@output_root, displaced_root)
      FileUtils.mkdir_p(File.dirname(destination))
      original_copy.call(source, destination, root: root, heartbeat: heartbeat)
    end

    Tempfile.create([ "book-", ".epub" ], staging) do |source|
      source.write("PK\x03\x04replacement-root")
      source.flush

      FileCopyService.stub(:cp_io_noreplace, swap_then_copy) do
        assert_raises(DirectDownloadFileService::Error) do
          @service.publish_file_and_finalize!(source)
        end
      end
    end

    assert_nil @book.reload.file_path
    assert @book.acquisition_reserved?
    assert @download.reload.downloading?
    assert @download.direct_staging_path.present?
    assert File.exist?(@destination)
    assert_not @service.cleanup_after_run!
  ensure
    if displaced_root && File.directory?(displaced_root)
      FileUtils.rm_rf(@output_root)
      File.rename(displaced_root, @output_root)
    end
  end

  test "publishes a complete directory at one atomic no-replace boundary" do
    service = directory_service
    staging = service.create_staging!
    source = File.join(staging, "extracted")
    FileUtils.mkdir_p(File.join(source, "disc"))
    File.binwrite(File.join(source, "chapter_01.mp3"), "one")
    File.binwrite(File.join(source, "disc", "chapter_02.mp3"), "two")

    assert service.publish_directory_and_finalize!(source)

    assert_not File.exist?(source)
    assert_equal "one", File.binread(File.join(directory_destination, "chapter_01.mp3"))
    assert_equal "two", File.binread(File.join(directory_destination, "disc", "chapter_02.mp3"))
    assert_equal 0o640, File.stat(File.join(directory_destination, "chapter_01.mp3")).mode & 0o777
    assert_equal 0o750, File.stat(File.join(directory_destination, "disc")).mode & 0o777
    assert_equal directory_destination, @book.reload.file_path
    assert service.cleanup_after_run!
  end

  test "a late directory conflict leaves no newly merged entries" do
    service = directory_service
    staging = service.create_staging!
    source = File.join(staging, "extracted")
    FileUtils.mkdir_p(source)
    File.binwrite(File.join(source, "chapter_01.mp3"), "replacement")
    File.binwrite(File.join(source, "chapter_02.mp3"), "new")
    FileUtils.mkdir_p(directory_destination)
    File.binwrite(File.join(directory_destination, "chapter_01.mp3"), "winner")

    assert_raises DirectDownloadFileService::ConflictError do
      service.publish_directory_and_finalize!(source)
    end

    assert_equal [ "chapter_01.mp3" ], Dir.children(directory_destination)
    assert_equal "winner", File.binread(File.join(directory_destination, "chapter_01.mp3"))
    assert File.exist?(File.join(source, "chapter_02.mp3"))
    assert_not @book.reload.acquisition_reserved?
    assert service.cleanup_after_run!
  end

  test "directory publication under a replaced output root never completes the Book" do
    service = directory_service
    staging = service.create_staging!
    source = File.join(staging, "extracted")
    FileUtils.mkdir_p(source)
    File.binwrite(File.join(source, "chapter.mp3"), "complete")
    displaced_root = "#{@output_root}-original"

    unsafe_publish = lambda do |source_path, destination, **_options|
      source_relative = Pathname(source_path).relative_path_from(Pathname(@output_root).expand_path)
      File.rename(@output_root, displaced_root)
      FileUtils.mkdir_p(File.dirname(destination))
      displaced_source = File.join(displaced_root, source_relative)
      File.rename(displaced_source, destination)
      destination
    end

    FileCopyService.stub(:mv_directory_noreplace, unsafe_publish) do
      assert_raises(DirectDownloadFileService::Error) do
        service.publish_directory_and_finalize!(source)
      end
    end

    assert_nil @book.reload.file_path
    assert @book.acquisition_reserved?
    assert @download.reload.downloading?
    assert @download.direct_staging_path.present?
    assert_equal "complete", File.binread(File.join(directory_destination, "chapter.mp3"))
    assert_not service.cleanup_after_run!
  ensure
    if displaced_root && File.directory?(displaced_root)
      FileUtils.rm_rf(@output_root)
      File.rename(displaced_root, @output_root)
    end
  end

  test "directory publication rejects symbolic links and FIFOs before reserving the Book" do
    skip "mkfifo is unavailable" unless File.respond_to?(:mkfifo)

    [ :symlink, :fifo ].each do |kind|
      service = directory_service
      staging = service.create_staging!
      source = File.join(staging, "extracted")
      FileUtils.mkdir_p(source)
      unsafe = File.join(source, "unsafe")
      if kind == :symlink
        outside = File.join(@output_root, "outside")
        File.binwrite(outside, "outside")
        File.symlink(outside, unsafe)
      else
        File.mkfifo(unsafe, 0o600)
      end

      assert_raises FileCopyService::UnsafePathError do
        service.publish_directory_and_finalize!(source)
      end
      assert_not @book.reload.acquisition_reserved?
      assert_not File.exist?(directory_destination)
      File.unlink(unsafe)
      assert service.cleanup_after_run!
    end
  end

  test "recovery finalizes a complete publication left after a hard exit" do
    staging = @service.create_staging!
    source_path = File.join(staging, "book.epub")
    bytes = "PK\x03\x04hard-exit-complete"
    File.binwrite(source_path, bytes)
    manifest = [ "file", bytes.bytesize, Digest::SHA256.hexdigest(bytes) ]
    @service.send(:persist_manifest!, manifest)
    @service.send(:reserve_book!)
    FileUtils.mkdir_p(File.dirname(@destination))
    FileCopyService.cp_noreplace(source_path, @destination, root: @output_root)
    @download.update_columns(status: Download.statuses[:failed], updated_at: 1.hour.ago)

    assert DirectDownloadFileService.reconcile!(@download)

    assert @download.reload.completed?
    assert @request.reload.completed?
    assert_equal File.dirname(@destination), @book.reload.file_path
    assert_equal bytes, File.binread(@destination)
    assert_nil @download.direct_staging_path
    assert_not File.exist?(staging)
  end

  test "monitor failure leases live staging until its atomic publication can be finalized" do
    staging = @service.create_staging!
    source_path = File.join(staging, "book.epub")
    bytes = "PK\x03\x04paused-worker-complete"
    File.binwrite(source_path, bytes)
    manifest = [ "file", bytes.bytesize, Digest::SHA256.hexdigest(bytes) ]
    @service.send(:persist_manifest!, manifest)
    @service.send(:reserve_book!)
    @download.update_columns(updated_at: DownloadMonitorJob::DIRECT_DOWNLOAD_STALE_TIMEOUT.ago - 1.minute)

    DownloadMonitorJob.new.send(:handle_stale_direct_download, @download.reload)

    assert @download.reload.failed?
    assert @book.reload.acquisition_reserved?
    assert_equal staging, @download.direct_staging_path
    assert File.directory?(staging)

    FileUtils.mkdir_p(File.dirname(@destination))
    FileCopyService.cp_noreplace(source_path, @destination, root: @output_root)

    assert DirectDownloadFileService.reconcile!(@download)
    assert @download.reload.completed?
    assert @request.reload.completed?
    assert_equal File.dirname(@destination), @book.reload.file_path
    assert_not File.exist?(staging)
  end

  test "recovery removes an incomplete hard-exit staging tree and releases its reservation" do
    staging = @service.create_staging!
    source_path = File.join(staging, "book.epub")
    bytes = "PK\x03\x04partial"
    File.binwrite(source_path, bytes)
    @service.send(:persist_manifest!, [ "file", bytes.bytesize, Digest::SHA256.hexdigest(bytes) ])
    @service.send(:reserve_book!)
    @download.update_columns(status: Download.statuses[:failed], updated_at: 1.hour.ago)

    assert_not DirectDownloadFileService.reconcile!(@download)

    assert_not @book.reload.acquisition_reserved?
    assert_nil @book.file_path
    assert_nil @download.reload.direct_staging_path
    assert_not File.exist?(staging)
  end

  test "recovery never deletes a replacement at the persisted staging pathname" do
    staging = @service.create_staging!
    displaced = "#{staging}-original"
    File.rename(staging, displaced)
    FileUtils.mkdir_p(staging)
    File.binwrite(File.join(staging, "replacement"), "preserve me")
    @download.update_columns(status: Download.statuses[:failed], updated_at: 1.hour.ago)

    assert_not DirectDownloadFileService.reconcile!(@download)

    assert_equal "preserve me", File.binread(File.join(staging, "replacement"))
    assert_equal staging, @download.reload.direct_staging_path
    assert File.directory?(displaced)
  end

  test "recovery retains state when the persisted staging parent was replaced" do
    staging = @service.create_staging!
    @service.send(:reserve_book!)
    parent = File.dirname(staging)
    displaced_parent = "#{parent}-original"
    File.rename(parent, displaced_parent)
    FileUtils.mkdir_p(parent)
    @download.update_columns(status: Download.statuses[:failed], updated_at: 1.hour.ago)

    assert_not DirectDownloadFileService.reconcile!(@download)

    assert_equal staging, @download.reload.direct_staging_path
    assert @book.reload.acquisition_reserved?
    assert File.directory?(File.join(displaced_parent, File.basename(staging)))
  end

  test "recovery clears state after the exact staging tree was already removed" do
    staging = @service.create_staging!
    snapshot = FileCopyService.snapshot_source_root(staging)
    assert FileCopyService.remove_source_tree(snapshot)
    @download.update_columns(status: Download.statuses[:failed], updated_at: 1.hour.ago)

    assert_not DirectDownloadFileService.reconcile!(@download)

    assert_nil @download.reload.direct_staging_path
    assert_not File.exist?(staging)
  end

  test "failed staging persistence never deletes a replacement at the created pathname" do
    displaced = nil
    service = @service
    relation = Object.new
    relation.define_singleton_method(:update_all) do |*_arguments, **_attributes|
      created_path = service.staging_path
      displaced = "#{created_path}-original"
      File.rename(created_path, displaced)
      FileUtils.mkdir_p(created_path)
      File.binwrite(File.join(created_path, "replacement"), "preserve me")
      0
    end

    Download.stub(:where, relation) do
      assert_raises(DirectDownloadFileService::Error) { @service.create_staging! }
    end

    assert_equal "preserve me", File.binread(File.join(@service.staging_path, "replacement"))
    assert File.directory?(displaced)
  end

  test "recovery retains state when the configured output root was replaced" do
    staging = @service.create_staging!
    @service.send(:reserve_book!)
    relative_staging = Pathname(staging).relative_path_from(Pathname(@output_root).expand_path)
    displaced_root = "#{@output_root}-original"
    File.rename(@output_root, displaced_root)
    FileUtils.mkdir_p(@output_root)
    replacement = File.join(Pathname(@output_root).realpath, relative_staging)
    FileUtils.mkdir_p(replacement)
    File.binwrite(File.join(replacement, "replacement"), "preserve me")
    @download.update_columns(status: Download.statuses[:failed], updated_at: 1.hour.ago)

    assert_not DirectDownloadFileService.reconcile!(@download)

    assert_equal "preserve me", File.binread(File.join(replacement, "replacement"))
    assert_equal staging, @download.reload.direct_staging_path
    assert @book.reload.acquisition_reserved?
    assert File.directory?(displaced_root)
  ensure
    FileUtils.rm_rf(displaced_root) if displaced_root
  end

  test "orphan cleanup reclaims only old unreferenced instance staging directories" do
    parent = DirectDownloadFileService.staging_parent(root: @output_root)
    orphan = Dir.mktmpdir("download-orphan-", parent)
    File.binwrite(File.join(orphan, "large.partial"), "partial")
    old = 2.days.ago.to_time
    File.utime(old, old, File.join(orphan, "large.partial"))
    File.utime(old, old, orphan)
    active = @service.create_staging!
    File.utime(old, old, active)

    assert_equal 1, DirectDownloadFileService.cleanup_orphans!(root: @output_root)

    assert_not File.exist?(orphan)
    assert File.directory?(active)
    @download.update!(status: :failed)
    DirectDownloadFileService.reconcile!(@download)
  end

  private

  def build_service
    DirectDownloadFileService.new(
      download: @download,
      book: @book,
      output_root: @output_root,
      destination_path: @destination,
      book_path: File.dirname(@destination),
      kind: :file
    )
  end

  def directory_destination
    File.join(@output_root, "Safety Author", "Direct Recovery Audio")
  end

  def directory_service
    @directory_service ||= DirectDownloadFileService.new(
      download: @download,
      book: @book,
      output_root: @output_root,
      destination_path: directory_destination,
      book_path: directory_destination,
      kind: :directory
    )
  end
end
