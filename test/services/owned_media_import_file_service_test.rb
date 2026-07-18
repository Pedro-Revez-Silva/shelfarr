# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class OwnedMediaImportFileServiceTest < ActiveSupport::TestCase
  setup do
    @output_root = Dir.mktmpdir("owned-media-file-service")
    @legacy_root = Dir.mktmpdir("owned-media-legacy-stage")
    SettingsService.set(:audiobook_output_path, @output_root)

    @connection = OwnedLibraryConnection.create!
    @item = @connection.owned_library_items.create!(
      external_id: "B000000001",
      title: "Crash Safe Book",
      authors: [ "Safe Author" ],
      ownership_type: "purchased"
    )
    @book = Book.create!(
      title: "Crash Safe Book",
      author: "Safe Author",
      book_type: :audiobook
    )
    @source = File.join(@legacy_root, "Safe Author - Crash Safe Book.m4b")
    File.binwrite(@source, "durable audiobook bytes")
    @upload = Upload.create!(
      user: users(:two),
      book: @book,
      original_filename: File.basename(@source),
      file_path: @source,
      file_size: File.size(@source),
      content_type: "audio/mp4",
      status: :processing
    )
    @media_import = @item.owned_media_imports.create!(
      requested_by: users(:two),
      upload: @upload,
      status: "processing"
    )
  end

  teardown do
    FileUtils.rm_rf(@output_root)
    FileUtils.rm_rf(@legacy_root)
  end

  test "migrates legacy Rails tmp staging onto the persistent audiobook filesystem" do
    destination = OwnedMediaImportFileService.ensure_persistent_staging!(
      @media_import,
      @upload
    )

    assert destination.start_with?(File.realpath(@output_root))
    assert_includes destination, "/.shelfarr-staging/uploads/"
    assert_equal "durable audiobook bytes", File.binread(destination)
    assert File.exist?(@source),
      "the temp-file sweeper removes the unreferenced legacy source without a path race"
    assert_equal destination, @upload.reload.file_path
  end

  test "cleans an incomplete durable copy when legacy staging migration fails" do
    partial_copy = lambda do |_source, destination|
      destination.write("partial")
      raise Errno::ENOSPC, "disk full"
    end

    OwnedMediaImportFileService.stub(:copy_io_contents, partial_copy) do
      assert_raises(Errno::ENOSPC) do
        OwnedMediaImportFileService.ensure_persistent_staging!(@media_import, @upload)
      end
    end

    stage_directory = OwnedMediaImportFileService.staging_upload_directory
    assert_empty Dir.children(stage_directory).grep(/libation_#{@media_import.id}/)
    assert_equal @source, @upload.reload.file_path
    assert_equal "durable audiobook bytes", File.binread(@source)
  end

  test "reconciles a hard exit after the destination link but before staging unlink" do
    service = persistent_service
    service.with_destination_lock { }
    destination = @media_import.reload.destination_path
    FileUtils.mkdir_p(File.dirname(destination))
    File.link(@upload.reload.file_path, destination)

    assert File.identical?(@upload.file_path, destination)
    result = service.with_destination_lock { service.finalize! }

    assert_equal File.dirname(destination), result
    assert File.exist?(destination)
    assert_not File.exist?(@upload.file_path)
    assert_equal "durable audiobook bytes", File.binread(destination)
  end

  test "reconciles a hard exit after staging unlink but before the database commit" do
    service = persistent_service
    result = service.with_destination_lock { service.finalize! }
    destination = @media_import.reload.destination_path

    assert_equal File.dirname(destination), result
    assert_not File.exist?(@upload.file_path)
    assert_equal destination,
      OwnedMediaImportFileService.recovery_source_path(@media_import, @upload.reload)
    assert_equal result, service.with_destination_lock { service.finalize! }
    assert_equal "durable audiobook bytes", File.binread(destination)
    assert_equal 0o640, File.stat(destination).mode & 0o777
  end

  test "filesystem capability probe verifies locking hard links and library permissions" do
    assert OwnedMediaImportFileService.verify_filesystem_capabilities!
    assert_empty Dir.glob(File.join(@output_root, ".shelfarr-capability-*"))
    assert_empty Dir.glob(File.join(
      @output_root,
      OwnedMediaImportFileService::STAGING_DIRECTORY,
      OwnedMediaImportFileService::UPLOADS_DIRECTORY,
      "*",
      ".capability-*"
    ))
  end

  test "filesystem capability probe rejects a mount without hard-link support" do
    unsupported_link = ->(*) { raise Errno::EPERM, "hard links disabled" }

    File.stub(:link, unsupported_link) do
      error = assert_raises(OwnedMediaImportFileService::Error) do
        OwnedMediaImportFileService.verify_filesystem_capabilities!
      end
      assert_match(/crash-safe finalization/, error.message)
    end
  end

  test "never overwrites a different file at a persisted destination" do
    service = persistent_service
    service.with_destination_lock { }
    destination = @media_import.reload.destination_path
    FileUtils.mkdir_p(File.dirname(destination))
    File.binwrite(destination, "someone else's bytes")

    error = assert_raises(OwnedMediaImportFileService::Error) do
      service.with_destination_lock { service.finalize! }
    end

    assert_match(/occupied|size changed/, error.message)
    assert_equal "someone else's bytes", File.binread(destination)
    assert_equal "durable audiobook bytes", File.binread(@upload.file_path)
  end

  test "rejects a same-size staged-file replacement after identity reservation" do
    service = persistent_service
    service.with_destination_lock { }
    original_size = File.size(@upload.file_path)
    File.unlink(@upload.file_path)
    File.binwrite(@upload.file_path, "x" * original_size)

    error = assert_raises(OwnedMediaImportFileService::Error) do
      service.with_destination_lock { service.finalize! }
    end

    assert_match(/identity changed/, error.message)
    assert_equal "x" * original_size, File.binread(@upload.file_path)
    assert_not File.exist?(@media_import.reload.destination_path)
  end

  test "rejects a same-size destination replacement during hard-exit recovery" do
    service = persistent_service
    service.with_destination_lock { service.finalize! }
    destination = @media_import.reload.destination_path
    original_size = File.size(destination)
    File.unlink(destination)
    File.binwrite(destination, "y" * original_size)

    error = assert_raises(OwnedMediaImportFileService::Error) do
      service.with_destination_lock { service.finalize! }
    end

    assert_match(/identity changed/, error.message)
    assert_equal "y" * original_size, File.binread(destination)
  end

  test "rejects a same-size source-only replacement before clearing recovery provenance" do
    service = persistent_service
    service.with_destination_lock do
      service.finalize!
      assert_equal OwnedMediaImportFileService::DESTINATION_RETAINED, service.restore_staging!
    end
    original_size = File.size(@upload.file_path)
    File.unlink(@upload.file_path)
    File.binwrite(@upload.file_path, "z" * original_size)

    error = assert_raises(OwnedMediaImportFileService::Error) do
      service.with_existing_destination_lock { service.restore_staging! }
    end

    assert_match(/identity changed/, error.message)
    assert @media_import.reload.destination_path.present?
    assert @media_import.staged_inode.present?
  end

  test "does not delete a concurrent destination when link publication loses the race" do
    service = persistent_service
    service.with_destination_lock { }
    destination = Pathname(@media_import.reload.destination_path)

    service.define_singleton_method(:native_linkat) do |_source_fd, _source_name, _destination_fd, _basename|
      File.binwrite(destination, "concurrent library bytes")
      raise Errno::EEXIST, destination.to_s
    end

    error = assert_raises(OwnedMediaImportFileService::Error) do
      service.with_destination_lock { service.finalize! }
    end

    assert_match(/became occupied/, error.message)
    assert_equal "concurrent library bytes", File.binread(destination)
    assert_equal "durable audiobook bytes", File.binread(@upload.file_path)
  end

  test "does not delete a replacement file after its own published link is displaced" do
    service = persistent_service
    service.with_destination_lock { }
    destination = Pathname(@media_import.reload.destination_path)
    service.define_singleton_method(:native_fchmod) do |_descriptor, _mode|
      File.unlink(destination)
      File.binwrite(destination, "replacement after publication")
      raise OwnedMediaImportFileService::Error, "simulated publication interruption"
    end

    assert_raises(OwnedMediaImportFileService::Error) do
      service.with_destination_lock { service.finalize! }
    end

    assert_equal "replacement after publication", File.binread(destination)
    assert_equal "durable audiobook bytes", File.binread(@upload.file_path)
  end

  test "rejects a library directory symlink which resolves outside the output root" do
    service = persistent_service
    service.with_destination_lock { }
    destination = Pathname(@media_import.reload.destination_path)
    outside = Dir.mktmpdir("owned-media-outside")
    FileUtils.mkdir_p(destination.dirname.parent)
    File.symlink(outside, destination.dirname)

    error = assert_raises(OwnedMediaImportFileService::Error) do
      service.with_destination_lock { service.finalize! }
    end

    assert_match(/resolves outside|symbolic link|non-directory/, error.message)
    assert_empty Dir.children(outside)
    assert_equal "durable audiobook bytes", File.binread(@upload.file_path)
  ensure
    FileUtils.rm_f(destination&.dirname)
    FileUtils.rm_rf(outside) if outside
  end

  test "rejects a symlinked library ancestor without creating descendants outside the output root" do
    SettingsService.set(:audiobook_path_template, "{author}/{title}")
    service = persistent_service
    service.with_destination_lock { }
    destination = Pathname(@media_import.reload.destination_path)
    outside = Dir.mktmpdir("owned-media-ancestor-outside")
    author_directory = destination.dirname.parent
    File.symlink(outside, author_directory)

    error = assert_raises(OwnedMediaImportFileService::Error) do
      service.with_destination_lock { service.finalize! }
    end

    assert_match(/symbolic link|non-directory/, error.message)
    assert_empty Dir.children(outside)
    assert_equal "durable audiobook bytes", File.binread(@upload.file_path)
  ensure
    FileUtils.rm_f(author_directory) if author_directory
    FileUtils.rm_rf(outside) if outside
  end

  test "pins the destination directory when its pathname is swapped during publication" do
    service = persistent_service
    service.with_destination_lock { }
    destination = Pathname(@media_import.reload.destination_path)
    FileUtils.mkdir_p(destination.dirname)
    moved_directory = Pathname("#{destination.dirname}-moved")
    outside = Pathname(Dir.mktmpdir("owned-media-link-swap"))
    real_linkat = service.method(:native_linkat)
    service.define_singleton_method(:native_linkat) do |source_fd, source_name, directory_fd, basename|
      File.rename(destination.dirname, moved_directory)
      File.symlink(outside, destination.dirname)
      real_linkat.call(source_fd, source_name, directory_fd, basename)
    end

    error = assert_raises(OwnedMediaImportFileService::Error) do
      service.with_destination_lock { service.finalize! }
    end

    assert_match(/changed during finalization/, error.message)
    assert_empty Dir.children(outside)
    assert_equal "durable audiobook bytes",
      File.binread(moved_directory.join(destination.basename))
    assert_equal "durable audiobook bytes", File.binread(@upload.file_path)
  ensure
    FileUtils.rm_f(destination&.dirname) if destination&.dirname&.symlink?
    FileUtils.rm_rf(moved_directory) if moved_directory
    FileUtils.rm_rf(outside) if outside
  end

  test "rejects an ancestor symlink inserted during component traversal" do
    SettingsService.set(:audiobook_path_template, "{author}/{title}")
    service = persistent_service
    service.with_destination_lock { }
    destination = Pathname(@media_import.reload.destination_path)
    author_directory = Pathname(@output_root).join(@book.author)
    moved_directory = Pathname("#{author_directory}-moved")
    outside = Pathname(Dir.mktmpdir("owned-media-ancestor-race"))
    real_openat = service.method(:native_openat)
    swapped = false
    service.define_singleton_method(:native_openat) do |directory_fd, basename, flags: nil|
      flags ||= File::RDONLY | File::NOFOLLOW
      if basename == @book.author && !swapped && author_directory.directory?
        swapped = true
        File.rename(author_directory, moved_directory)
        File.symlink(outside, author_directory)
      end
      real_openat.call(directory_fd, basename, flags: flags)
    end

    assert_raises(OwnedMediaImportFileService::Error) do
      service.with_destination_lock { service.finalize! }
    end

    assert_empty Dir.children(outside)
    assert_not File.exist?(moved_directory.join(destination.dirname.basename, destination.basename))
    assert_equal "durable audiobook bytes", File.binread(@upload.file_path)
  ensure
    FileUtils.rm_f(author_directory) if author_directory&.symlink?
    FileUtils.rm_rf(moved_directory) if moved_directory
    FileUtils.rm_rf(outside) if outside
  end

  test "reserves distinct destinations for concurrent editions of the same title" do
    first_service = persistent_service
    first_service.with_destination_lock { }
    first_destination = @media_import.reload.destination_path

    second_item = @connection.owned_library_items.create!(
      external_id: "B000000002",
      title: @book.title,
      authors: [ @book.author ],
      ownership_type: "purchased"
    )
    second_book = Book.create!(
      title: @book.title,
      author: @book.author,
      book_type: :audiobook
    )
    second_import = second_item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "processing"
    )
    second_source = OwnedMediaImportFileService.staging_path_for(second_import, ".m4b")
    File.binwrite(second_source, "second edition")
    second_upload = Upload.create!(
      user: users(:two),
      book: second_book,
      original_filename: @upload.original_filename,
      file_path: second_source.to_s,
      file_size: second_source.size,
      content_type: "audio/mp4",
      status: :processing
    )
    second_import.update!(upload: second_upload)
    second_service = OwnedMediaImportFileService.new(
      media_import: second_import,
      upload: second_upload,
      book: second_book
    )
    second_service.with_destination_lock { }

    assert_equal "#{File.dirname(first_destination)} (2)",
      File.dirname(second_import.reload.destination_path)
    assert_not_equal first_destination, second_import.destination_path
  end

  test "different filenames cannot reserve the same directory-mode library path" do
    SettingsService.set(:audiobook_path_template, "{title}")
    first_service = persistent_service
    first_service.with_destination_lock { }
    first_library_path = @media_import.reload.library_path

    second_item = @connection.owned_library_items.create!(
      external_id: "B000000003",
      title: @book.title,
      authors: [ "Different Author" ],
      ownership_type: "purchased"
    )
    second_book = Book.create!(
      title: @book.title,
      author: "Different Author",
      book_type: :audiobook
    )
    second_import = second_item.owned_media_imports.create!(
      requested_by: users(:two),
      status: "processing"
    )
    second_source = OwnedMediaImportFileService.staging_path_for(second_import, ".m4b")
    File.binwrite(second_source, "different filename")
    second_upload = Upload.create!(
      user: users(:two),
      book: second_book,
      original_filename: "Different Author - Crash Safe Book.m4b",
      file_path: second_source.to_s,
      file_size: second_source.size,
      content_type: "audio/mp4",
      status: :processing
    )
    second_import.update!(upload: second_upload)
    second_service = OwnedMediaImportFileService.new(
      media_import: second_import,
      upload: second_upload,
      book: second_book
    )
    second_service.with_destination_lock { }

    assert_equal "#{first_library_path} (2)", second_import.reload.library_path
    assert_not_equal File.basename(@media_import.destination_path),
      File.basename(second_import.destination_path)
  end

  test "a path-template change cannot alter a previously reserved book path" do
    service = persistent_service
    service.with_destination_lock { }
    reserved_library_path = @media_import.reload.library_path
    SettingsService.set(:audiobook_path_template, "")

    retried_service = OwnedMediaImportFileService.new(
      media_import: @media_import,
      upload: @upload.reload,
      book: @book
    )
    result = retried_service.with_destination_lock { retried_service.finalize! }

    assert_equal reserved_library_path, result
    assert_equal File.dirname(@media_import.destination_path), result
  end

  test "ordinary rollback retains the exact reservation for a safe retry" do
    service = persistent_service
    service.with_destination_lock do
      service.finalize!
      assert_equal OwnedMediaImportFileService::DESTINATION_RETAINED, service.restore_staging!
    end
    first_directory = File.join(File.realpath(@output_root), @book.author, @book.title)

    assert File.exist?(first_directory)
    retried_service = OwnedMediaImportFileService.new(
      media_import: @media_import.reload,
      upload: @upload.reload,
      book: @book
    )
    retried_service.with_destination_lock { }
    assert_equal first_directory, @media_import.reload.library_path
  end

  test "directory-cleanup interruption keeps the destination reservation durable" do
    service = persistent_service
    service.with_destination_lock do
      service.finalize!
      assert_equal OwnedMediaImportFileService::DESTINATION_RETAINED, service.restore_staging!
      service.stub(:remove_empty_created_directories!, -> { raise IOError, "worker stopped" }) do
        assert_raises(IOError) { service.clear_reservation! }
      end
    end

    assert @media_import.reload.destination_path.present?
    assert @media_import.library_path.present?
  end

  test "backfills the library path for a reservation made by an older worker" do
    service = persistent_service
    service.with_destination_lock { }
    destination = @media_import.reload.destination_path
    @media_import.update_column(:library_path, nil)

    result = service.with_destination_lock { service.finalize! }

    assert_equal File.dirname(destination), result
    assert_equal result, @media_import.reload.library_path
  end

  test "fails closed when the filesystem cannot acquire the destination lock" do
    fake_stat = Struct.new(:file?).new(true)
    fake_lock = Struct.new(:stat) do
      def flock(*) = false
      def fileno = 123
      def close = @closed = true
      def closed? = @closed == true
    end.new(fake_stat)

    File.stub(:for_fd, fake_lock) do
      OwnedMediaImportFileService.stub(:class_native_fchmod, nil) do
      error = assert_raises(OwnedMediaImportFileService::Error) do
        OwnedMediaImportFileService.with_lock(@output_root, "unsupported-lock") { flunk }
      end
      assert_match(/required lock/, error.message)
      end
    end
  end

  test "concurrent first use safely shares staging directory initialization" do
    fresh_root = Dir.mktmpdir("owned-media-concurrent-stage")
    FileUtils.rm_rf(File.join(fresh_root, OwnedMediaImportFileService::STAGING_DIRECTORY))
    errors = Queue.new
    ready = Queue.new
    start = Queue.new
    thread_count = 4
    threads = thread_count.times.map do
      Thread.new do
        ready << true
        start.pop
        OwnedMediaImportFileService.staging_upload_directory(root: fresh_root)
      rescue StandardError => error
        errors << error
      end
    end
    thread_count.times { ready.pop }
    thread_count.times { start << true }
    threads.each(&:join)

    assert errors.empty?, "concurrent initialization failed: #{errors.pop.inspect unless errors.empty?}"
    assert File.directory?(File.join(
      fresh_root,
      OwnedMediaImportFileService::STAGING_DIRECTORY,
      OwnedMediaImportFileService::UPLOADS_DIRECTORY
    ))
  ensure
    FileUtils.rm_rf(fresh_root) if fresh_root
  end

  test "rejects a symlinked staging directory without changing its target" do
    outside = Dir.mktmpdir("owned-media-stage-symlink-target")
    File.chmod(0o755, outside)
    staging = File.join(@output_root, OwnedMediaImportFileService::STAGING_DIRECTORY)
    File.symlink(outside, staging)

    assert_raises(OwnedMediaImportFileService::Error) do
      OwnedMediaImportFileService.staging_upload_directory(root: @output_root)
    end
    assert_equal 0o755, File.stat(outside).mode & 0o777
  ensure
    FileUtils.rm_f(staging) if staging
    FileUtils.rm_rf(outside) if outside
  end

  test "uses a bounded lock namespace" do
    1_050.times do |index|
      OwnedMediaImportFileService.with_lock(@output_root, "adversarial-title-#{index}") { }
    end

    locks = Dir.glob(File.join(
      @output_root,
      OwnedMediaImportFileService::STAGING_DIRECTORY,
      OwnedMediaImportFileService::LOCKS_DIRECTORY,
      "lock-*"
    ))
    assert_operator locks.length, :<=, OwnedMediaImportFileService::LOCK_SHARDS
    assert locks.all? { |path| File.file?(path) && (File.stat(path).mode & 0o777) == 0o600 }
  end

  private

  def persistent_service
    OwnedMediaImportFileService.ensure_persistent_staging!(@media_import, @upload)
    @upload.reload
    OwnedMediaImportFileService.new(
      media_import: @media_import,
      upload: @upload,
      book: @book
    )
  end
end
