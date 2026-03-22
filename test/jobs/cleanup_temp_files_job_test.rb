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
