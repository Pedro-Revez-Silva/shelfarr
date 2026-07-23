# frozen_string_literal: true

require "test_helper"

class WatchedFolderScanJobTest < ActiveJob::TestCase
  # The default test cache is a null store, so status writes would be dropped.
  # Swap in a real in-memory store for the duration of each test so the
  # running/idle transitions are observable.
  def with_memory_cache
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) { yield }
  end

  test "scan status starts empty" do
    with_memory_cache do
      assert_equal({}, WatchedFolderScanJob.scan_status)
      assert_not WatchedFolderScanJob.scanning_now?
    end
  end

  test "status transitions from running to idle and records the result" do
    with_memory_cache do
      WatchedFolderScanJob.mark_running!
      assert WatchedFolderScanJob.scanning_now?

      result = WatchedFolderScanService::Result.new(scanned: 5, detected: 3, skipped: 2)
      WatchedFolderScanJob.mark_completed!(result)

      assert_not WatchedFolderScanJob.scanning_now?
      status = WatchedFolderScanJob.scan_status
      assert_equal "idle", status[:state]
      assert_equal 3, status[:detected]
      assert_equal 5, status[:scanned]
      assert_not status[:failed]
      assert status[:completed_at].present?
    end
  end

  test "a failed scan is recorded as failed" do
    with_memory_cache do
      WatchedFolderScanJob.mark_completed!(nil)
      status = WatchedFolderScanJob.scan_status
      assert_equal "idle", status[:state]
      assert status[:failed]
    end
  end

  test "a manual scan records its completion" do
    watched = Dir.mktmpdir("wfsj-watched")
    audiobook_dest = Dir.mktmpdir("wfsj-audiobooks")
    set_setting("audiobook_output_path", audiobook_dest, "paths")
    set_setting("library_import_enabled", "true", "import", "boolean")
    set_setting("library_import_path", watched, "import")
    File.write(File.join(watched, "Some Author - A Book.epub"), "dummy epub")

    with_memory_cache do
      MetadataService.stub(:search, []) do
        WatchedFolderScanJob.new.perform(manual: true)
      end
      status = WatchedFolderScanJob.scan_status
      assert_equal "idle", status[:state]
      assert_equal 1, status[:detected]
    end
  ensure
    [ watched, audiobook_dest ].each { |dir| FileUtils.rm_rf(dir) if dir }
  end

  private

  def set_setting(key, value, category = "paths", value_type = "string")
    Setting.find_or_create_by(key: key).update!(
      value: value, value_type: value_type, category: category
    )
  end
end
