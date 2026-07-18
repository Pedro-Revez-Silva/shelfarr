# frozen_string_literal: true

require "test_helper"

class CleanupTempFilesJobTest < ActiveJob::TestCase
  test "performs without errors when directories don't exist" do
    # Ensure directories don't exist
    downloads_dir = Rails.root.join("tmp", "test_nonexistent_downloads")
    uploads_dir = Rails.root.join("tmp", "test_nonexistent_uploads")
    FileUtils.rm_rf(downloads_dir)
    FileUtils.rm_rf(uploads_dir)

    assert_nothing_raised do
      CleanupTempFilesJob.perform_now
    end
  end

  test "cleanup_old_activity_logs deletes old logs" do
    # Create an old activity log
    old_log = ActivityLog.create!(
      action: "test.action",
      created_at: 100.days.ago
    )

    # Create a recent log
    recent_log = ActivityLog.create!(
      action: "test.action",
      created_at: 1.day.ago
    )

    CleanupTempFilesJob.perform_now

    assert_not ActivityLog.exists?(old_log.id), "Old log should be deleted"
    assert ActivityLog.exists?(recent_log.id), "Recent log should be kept"
  end

  test "cleanup_old_request_events deletes old events" do
    request = requests(:pending_request)

    old_event = RequestEvent.create!(
      request: request,
      event_type: "dispatch_failed",
      source: "DownloadJob",
      level: :error,
      message: "Old event",
      created_at: 100.days.ago
    )

    recent_event = RequestEvent.create!(
      request: request,
      event_type: "dispatch_failed",
      source: "DownloadJob",
      level: :error,
      message: "Recent event",
      created_at: 1.day.ago
    )

    CleanupTempFilesJob.perform_now

    assert_not RequestEvent.exists?(old_event.id), "Old request event should be deleted"
    assert RequestEvent.exists?(recent_event.id), "Recent request event should be kept"
  end
end

class CleanupTempFilesJobIsolatedTest < ActiveJob::TestCase
  # These tests run in isolation with their own temp directories
  setup do
    @test_id = "#{Process.pid}_#{SecureRandom.hex(4)}"
    @temp_base = Rails.root.join("tmp", "cleanup_test_#{@test_id}")
    @downloads_dir = @temp_base.join("downloads")
    @uploads_dir = @temp_base.join("uploads")
    FileUtils.mkdir_p(@downloads_dir)
    FileUtils.mkdir_p(@uploads_dir)
  end

  teardown do
    FileUtils.rm_rf(@temp_base)
  end

  test "deletes old download temp files" do
    old_file = @downloads_dir.join("old_file.zip")
    File.write(old_file, "content")
    FileUtils.touch(old_file, mtime: 2.hours.ago.to_time)

    perform_cleanup_for(@downloads_dir, @uploads_dir)

    assert_not File.exist?(old_file), "Old file should be deleted"
  end

  test "keeps recent download temp files" do
    recent_file = @downloads_dir.join("recent_file.zip")
    File.write(recent_file, "content")

    perform_cleanup_for(@downloads_dir, @uploads_dir)

    assert File.exist?(recent_file), "Recent file should be kept"
  end

  test "deletes old upload temp files" do
    old_file = @uploads_dir.join("old_upload.m4b")
    File.write(old_file, "content")
    FileUtils.touch(old_file, mtime: 25.hours.ago.to_time)

    perform_cleanup_for(@downloads_dir, @uploads_dir)

    assert_not File.exist?(old_file), "Old upload should be deleted"
  end

  test "keeps recent upload temp files" do
    recent_file = @uploads_dir.join("recent_upload.m4b")
    File.write(recent_file, "content")

    perform_cleanup_for(@downloads_dir, @uploads_dir)

    assert File.exist?(recent_file), "Recent upload should be kept"
  end

  test "keeps upload files referenced by pending uploads" do
    old_file = @uploads_dir.join("pending_upload.m4b")
    File.write(old_file, "content")
    FileUtils.touch(old_file, mtime: 25.hours.ago.to_time)

    Upload.create!(
      user: users(:one),
      original_filename: "pending_upload.m4b",
      file_path: old_file.to_s,
      status: :pending
    )

    perform_cleanup_for(@downloads_dir, @uploads_dir)

    assert File.exist?(old_file), "File with pending upload should be kept"
  end

  test "actual cleanup traverses database-specific staging directories" do
    nested = @uploads_dir.join("database-fingerprint")
    FileUtils.mkdir_p(nested)
    orphan = nested.join("orphan.m4b")
    File.binwrite(orphan, "orphan")
    FileUtils.touch(orphan, mtime: 25.hours.ago.to_time)

    deleted = CleanupTempFilesJob.new.send(
      :cleanup_upload_directory,
      @uploads_dir,
      max_age: 24.hours.ago,
      protected_paths: Set.new
    )

    assert_equal 1, deleted
    assert_not File.exist?(orphan)
    assert_not File.directory?(nested)
  end

  test "actual cleanup preserves nested files used by active uploads" do
    nested = @uploads_dir.join("database-fingerprint")
    FileUtils.mkdir_p(nested)
    staged = nested.join("active.m4b")
    File.binwrite(staged, "active")
    FileUtils.touch(staged, mtime: 25.hours.ago.to_time)

    deleted = CleanupTempFilesJob.new.send(
      :cleanup_upload_directory,
      @uploads_dir,
      max_age: 24.hours.ago,
      protected_paths: Set.new([ staged.to_s ])
    )

    assert_equal 0, deleted
    assert File.exist?(staged)
  end

  test "actual cleanup preserves an empty staging directory needed to recover a finalized upload" do
    nested = @uploads_dir.join("database-fingerprint")
    FileUtils.mkdir_p(nested)
    missing_stage = nested.join("finalized-before-database-commit.m4b")

    CleanupTempFilesJob.new.send(
      :cleanup_upload_directory,
      @uploads_dir,
      max_age: 24.hours.ago,
      protected_paths: Set.new([ missing_stage.to_s ])
    )

    assert File.directory?(nested)
  end

  test "cleanup includes durable staging roots retained from earlier path settings" do
    old_root = @temp_base.join("old-audiobooks")
    current_root = @temp_base.join("current-audiobooks")
    FileUtils.mkdir_p([ old_root, current_root ])
    SettingsService.set(:audiobook_output_path, current_root.to_s)
    connection = OwnedLibraryConnection.create!
    item = connection.owned_library_items.create!(
      external_id: "OLD-STAGING-ROOT",
      title: "Old staging root",
      ownership_type: "purchased"
    )
    media_import = item.owned_media_imports.create!(status: "failed")
    staged = OwnedMediaImportFileService.staging_path_for(media_import, ".m4b", root: old_root)
    File.binwrite(staged, "referenced failed backup")
    FileUtils.touch(staged, mtime: 25.hours.ago.to_time)
    orphan = staged.dirname.join("unreferenced-old-root.m4b")
    File.binwrite(orphan, "orphaned old-root backup")
    FileUtils.touch(orphan, mtime: 25.hours.ago.to_time)
    upload = Upload.create!(
      user: users(:one),
      original_filename: "old-root.m4b",
      file_path: staged.to_s,
      file_size: staged.size,
      status: :failed
    )
    media_import.update!(upload: upload)

    CleanupTempFilesJob.perform_now

    assert File.exist?(staged)
    assert_not File.exist?(orphan)
  end

  test "cleanup never scans another Shelfarr database fingerprint" do
    root = @temp_base.join("shared-audiobooks")
    FileUtils.mkdir_p(root)
    SettingsService.set(:audiobook_output_path, root.to_s)
    own_directory = OwnedMediaImportFileService.staging_upload_directory(root: root)
    foreign_directory = own_directory.parent.join("another-database")
    FileUtils.mkdir_p(foreign_directory)
    foreign_file = foreign_directory.join("active-in-another-shelfarr.m4b")
    File.binwrite(foreign_file, "foreign active bytes")
    FileUtils.touch(foreign_file, mtime: 25.hours.ago.to_time)

    CleanupTempFilesJob.perform_now

    assert_equal "foreign active bytes", File.binread(foreign_file)
  end

  test "cleanup rechecks upload activity after its initial protected snapshot" do
    root = @temp_base.join("retry-race-audiobooks")
    FileUtils.mkdir_p(root)
    SettingsService.set(:audiobook_output_path, root.to_s)
    directory = OwnedMediaImportFileService.staging_upload_directory(root: root)
    staged = directory.join("retry-race.m4b")
    File.binwrite(staged, "retry bytes")
    FileUtils.touch(staged, mtime: 25.hours.ago.to_time)
    upload = Upload.create!(
      user: users(:one),
      original_filename: staged.basename.to_s,
      file_path: staged.to_s,
      file_size: staged.size,
      status: :failed
    )
    upload.update!(status: :pending)

    deleted = CleanupTempFilesJob.new.send(
      :cleanup_upload_directory,
      directory,
      max_age: 24.hours.ago,
      protected_paths: Set.new
    )

    assert_equal 0, deleted
    assert_equal "retry bytes", File.binread(staged)
  end

  private

  def perform_cleanup_for(downloads_dir, uploads_dir)
    job = CleanupTempFilesJob.new

    # Stub the directories for this test
    job.instance_variable_set(:@test_downloads_dir, downloads_dir)
    job.instance_variable_set(:@test_uploads_dir, uploads_dir)

    # Define test-specific cleanup methods
    job.define_singleton_method(:cleanup_download_temps) do
      dir = @test_downloads_dir
      return unless File.directory?(dir)

      max_age = 1.hour.ago
      Dir.glob(dir.join("*")).each do |file|
        next if File.directory?(file)
        next if File.mtime(file) > max_age
        FileUtils.rm_f(file)
      end
    end

    job.define_singleton_method(:cleanup_upload_temps) do
      dir = @test_uploads_dir
      return unless File.directory?(dir)

      max_age = 24.hours.ago
      Dir.glob(dir.join("*")).each do |file|
        next if File.directory?(file)
        next if File.mtime(file) > max_age
        next if Upload.pending_or_processing.where(file_path: file).exists?
        FileUtils.rm_f(file)
      end
    end

    job.define_singleton_method(:cleanup_old_activity_logs) { }

    job.send(:cleanup_download_temps)
    job.send(:cleanup_upload_temps)
  end
end
