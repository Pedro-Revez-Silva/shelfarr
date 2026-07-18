# frozen_string_literal: true

require "test_helper"

class RecurringConfigTest < ActiveSupport::TestCase
  test "schedules book metadata backfill daily" do
    config = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    default_jobs = config.fetch("default")
    backfill_job = default_jobs.fetch("book_metadata_backfill")

    assert_equal "BookMetadataBackfillJob", backfill_job["class"]
    assert_equal "default", backfill_job["queue"]
    assert_equal "at 3am every day", backfill_job["schedule"]
  end

  test "dispatches owned library automation every five minutes" do
    config = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    automation_job = config.fetch("default").fetch("owned_library_automation")

    assert_equal "OwnedLibraryAutomationJob", automation_job["class"]
    assert_equal "default", automation_job["queue"]
    assert_equal "every 5 minutes", automation_job["schedule"]
  end

  test "recovers stranded uploads every five minutes" do
    config = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    recovery_job = config.fetch("default").fetch("upload_recovery")

    assert_equal "UploadRecoveryJob", recovery_job["class"]
    assert_equal "default", recovery_job["queue"]
    assert_equal "every 5 minutes", recovery_job["schedule"]
  end

  test "recovers stranded direct downloads every five minutes" do
    config = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    recovery_job = config.fetch("default").fetch("direct_download_recovery")

    assert_equal "DirectDownloadRecoveryJob", recovery_job["class"]
    assert_equal "default", recovery_job["queue"]
    assert_equal "every 5 minutes", recovery_job["schedule"]
  end

  test "recovers stranded post-processing every five minutes" do
    config = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    recovery_job = config.fetch("default").fetch("post_processing_recovery")

    assert_equal "PostProcessingRecoveryJob", recovery_job["class"]
    assert_equal "default", recovery_job["queue"]
    assert_equal "every 5 minutes", recovery_job["schedule"]
  end
end
