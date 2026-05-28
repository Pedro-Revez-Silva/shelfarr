# frozen_string_literal: true

require "test_helper"

class WatchDirectoryJobTest < ActiveJob::TestCase
  setup do
    @admin = users(:two)
    @watch_dir = Rails.root.join("tmp", "test_watch_#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@watch_dir)
    SettingsService.set(:watch_directory_path, @watch_dir.to_s)
    SettingsService.set(:watch_directory_interval, 1) # Ensure enabled
    Setting.find_by(key: "watch_directory_last_run_at")&.destroy # Clear state for tests
  end

  teardown do
    FileUtils.rm_rf(@watch_dir)
    FileUtils.rm_rf(Rails.root.join("tmp", "uploads"))
  end

  test "processes a single ebook file" do
    epub_path = @watch_dir.join("test.epub")
    File.write(epub_path, "fake epub content")

    assert_difference "Upload.count", 1 do
      assert_enqueued_with(job: UploadProcessingJob) do
        WatchDirectoryJob.perform_now
      end
    end

    upload = Upload.last
    assert_equal "test.epub", upload.original_filename
    assert_equal epub_path.to_s, upload.watch_dir_path
    assert_equal @admin, upload.user
  end

  test "skips directory with multiple audio files" do
    subdir = @watch_dir.join("multi_audio")
    FileUtils.mkdir_p(subdir)
    File.write(subdir.join("track1.mp3"), "audio1")
    File.write(subdir.join("track2.mp3"), "audio2")

    assert_no_difference "Upload.count" do
      WatchDirectoryJob.perform_now
    end
  end

  test "processes a single audio file in a directory" do
    subdir = @watch_dir.join("single_audio")
    FileUtils.mkdir_p(subdir)
    mp3_path = subdir.join("book.mp3")
    File.write(mp3_path, "audio content")

    assert_difference "Upload.count", 1 do
      WatchDirectoryJob.perform_now
    end

    assert_equal mp3_path.to_s, Upload.last.watch_dir_path
  end

  test "does not process the same file twice" do
    epub_path = @watch_dir.join("test.epub")
    File.write(epub_path, "fake epub content")

    # First run
    assert_difference "Upload.count", 1 do
      WatchDirectoryJob.perform_now
    end

    # Second run
    assert_no_difference "Upload.count" do
      WatchDirectoryJob.perform_now
    end
  end

  test "processes multiple independent files" do
    File.write(@watch_dir.join("book1.epub"), "content1")
    File.write(@watch_dir.join("book2.pdf"), "content2")

    assert_difference "Upload.count", 2 do
      WatchDirectoryJob.perform_now
    end
  end
end
