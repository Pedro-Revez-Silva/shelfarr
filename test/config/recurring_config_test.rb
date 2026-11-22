# frozen_string_literal: true

require "test_helper"

class RecurringConfigTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

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

  test "does not statically tick health checks or library sync every minute" do
    config = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    %w[default production].each do |env_name|
      jobs = config.fetch(env_name)
      assert_nil jobs["health_check"]
      assert_nil jobs["audiobookshelf_library_sync"]
    end
  end

  test "scheduler startup enqueues a due health check" do
    SolidQueue::Record.establish_connection(:queue)
    SystemHealth.delete_all
    scheduler = SolidQueue::Scheduler.new(recurring_tasks: [])

    assert_enqueued_with(job: HealthCheckJob, args: [ { scheduled: true } ]) do
      scheduler.send(:run_start_hooks)
    end
  ensure
    scheduler&.send(:run_stop_hooks)
  end

  test "schedules the download monitor class and has no command entry" do
    config = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    default_jobs = config.fetch("default")
    assert_nil default_jobs["download_monitor_recovery"]
    monitor = default_jobs.fetch("download_monitor")

    assert_equal "DownloadMonitorJob", monitor["class"]
    assert_equal "default", monitor["queue"]
    assert_equal [ { "scheduled" => true } ], monitor["args"]
    assert_equal "every minute", monitor["schedule"]
    assert_nil monitor["command"]

    production = config.fetch("production")
    assert_nil production["download_monitor_recovery"]
    assert_equal "DownloadMonitorJob", production.fetch("download_monitor").fetch("class")
    assert_nil production.fetch("download_monitor")["command"]
  end

  test "checks Hardcover subscriptions every fifteen minutes" do
    config = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    job = config.fetch("default").fetch("hardcover_sync")

    assert_equal "HardcoverSyncSchedulerJob", job["class"]
    assert_equal "default", job["queue"]
    assert_equal "every 15 minutes", job["schedule"]
  end
end
