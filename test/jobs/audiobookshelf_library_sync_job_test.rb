# frozen_string_literal: true

require "test_helper"

class AudiobookshelfLibrarySyncJobTest < ActiveJob::TestCase
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")
    SettingsService.set(:audiobookshelf_audiobook_library_id, "lib-audio")
    SettingsService.set(:audiobookshelf_ebook_library_id, "")
    SettingsService.set(:audiobookshelf_library_sync_interval, 3600)
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "does not schedule next run after syncing (recurring job handles scheduling)" do
    LibraryItem.destroy_all

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries/lib-audio/items")
        .with(
          headers: { "Authorization" => "Bearer test-api-key" },
          query: hash_including("limit" => "500", "page" => "0")
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [
              {
                "id" => "ab-1",
                "title" => "The Hobbit",
                "author" => "J.R.R. Tolkien"
              }
            ],
            "total" => 1
          }.to_json
        )

      assert_no_enqueued_jobs(only: AudiobookshelfLibrarySyncJob) do
        AudiobookshelfLibrarySyncJob.perform_now
      end
    end

    assert_equal 1, LibraryItem.count
    assert_equal "The Hobbit", LibraryItem.first.title
  end

  test "cleanup discards only identifiable legacy delayed periodic jobs" do
    SolidQueue::Record.establish_connection(:queue)

    legacy_no_args = create_queue_abs_sync_job(scheduled_at: 1.hour.from_now)
    legacy_with_schedule_next_true = create_queue_abs_sync_job(
      scheduled_at: 1.hour.from_now,
      arguments: { schedule_next: true }
    )
    manual = create_queue_abs_sync_job(scheduled_at: Time.current)
    post_scan = create_queue_abs_sync_job(
      scheduled_at: 90.seconds.from_now,
      arguments: { schedule_next: false }
    )
    current_post_scan = create_queue_abs_sync_job(
      scheduled_at: 90.seconds.from_now,
      arguments: { post_scan: true }
    )
    recurring = create_queue_abs_sync_job(
      scheduled_at: 1.hour.from_now,
      arguments: { scheduled: true }
    )
    SolidQueue::RecurringExecution.create!(
      job: recurring,
      task_key: "audiobookshelf_library_sync",
      run_at: 1.hour.from_now
    )
    claimed = create_queue_abs_sync_job(scheduled_at: 1.hour.from_now)
    claimed.scheduled_execution.destroy!
    process = SolidQueue::Process.register(
      kind: "Worker",
      name: "abs-sync-cleanup-test-#{SecureRandom.hex(4)}",
      pid: Process.pid,
      hostname: "test",
      metadata: {}
    )
    SolidQueue::ClaimedExecution.create!(job: claimed, process: process)

    assert_equal 2, AudiobookshelfLibrarySyncJob.discard_legacy_scheduled_chains!

    assert_not SolidQueue::Job.exists?(legacy_no_args.id)
    assert_not SolidQueue::Job.exists?(legacy_with_schedule_next_true.id)
    [ manual, post_scan, current_post_scan, recurring, claimed ].each do |preserved|
      assert SolidQueue::Job.exists?(preserved.id), "expected job #{preserved.id} to be preserved"
    end
  end

  test "pre-migration post-scan jobs still execute as one-shots" do
    sync_service = Minitest::Mock.new
    sync_service.expect(:sync!, true)

    AudiobookshelfLibrarySyncService.stub(:new, sync_service) do
      assert_no_enqueued_jobs(only: AudiobookshelfLibrarySyncJob) do
        AudiobookshelfLibrarySyncJob.perform_now(schedule_next: false)
      end
    end

    sync_service.verify
  end

  test "scheduled syncs honor the configured interval on minute boundaries" do
    SettingsService.set(:audiobookshelf_library_sync_interval, 600)

    travel_to Time.zone.parse("2026-08-26 12:00:00") do
      job = AudiobookshelfLibrarySyncJob.new
      Rails.cache.write(
        AudiobookshelfLibrarySyncJob::LAST_SCHEDULED_ATTEMPT_AT_CACHE_KEY,
        9.minutes.ago
      )
      assert_not job.send(:sync_due?)

      Rails.cache.write(
        AudiobookshelfLibrarySyncJob::LAST_SCHEDULED_ATTEMPT_AT_CACHE_KEY,
        10.minutes.ago
      )
      assert job.send(:sync_due?)
    end
  end

  test "zero interval disables scheduled syncs" do
    SettingsService.set(:audiobookshelf_library_sync_interval, 0)

    assert_not AudiobookshelfLibrarySyncJob.new.send(:sync_due?)
  end

  test "scheduled syncs record an attempt even when the remote library is empty" do
    SettingsService.set(:audiobookshelf_library_sync_interval, 86_400)
    LibraryItem.destroy_all
    sync_service = Minitest::Mock.new
    sync_service.expect(:sync!, true)

    AudiobookshelfLibrarySyncService.stub(:new, sync_service) do
      AudiobookshelfLibrarySyncJob.perform_now(scheduled: true)
    end

    sync_service.verify
    assert_empty LibraryItem.all
    assert_not AudiobookshelfLibrarySyncJob.new.send(:sync_due?)
  end

  test "post-scan refresh enqueues a delayed one-shot sync" do
    clear_enqueued_jobs

    with_post_scan_refresh_cache do
      assert_enqueued_with(
        job: AudiobookshelfLibrarySyncJob,
        args: [ { post_scan: true } ],
        at: AudiobookshelfLibrarySyncJob::POST_SCAN_REFRESH_WAIT.from_now
      ) do
        AudiobookshelfLibrarySyncJob.schedule_post_scan_refresh!
      end
    end
  end

  test "post-scan refresh coalesces repeated calls into one delayed job" do
    clear_enqueued_jobs

    with_post_scan_refresh_cache do
      assert_enqueued_jobs 1, only: AudiobookshelfLibrarySyncJob do
        5.times { AudiobookshelfLibrarySyncJob.schedule_post_scan_refresh! }
      end
    end
  end

  test "post-scan refresh is a no-op when no platform is configured" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobookshelf_api_key, "")
    SettingsService.set(:bookorbit_url, "")
    SettingsService.set(:grimmory_url, "")
    clear_enqueued_jobs

    assert_no_enqueued_jobs(only: AudiobookshelfLibrarySyncJob) do
      AudiobookshelfLibrarySyncJob.schedule_post_scan_refresh!
    end
  end

  private

  def create_queue_abs_sync_job(scheduled_at:, arguments: {})
    active_job = arguments.empty? ? AudiobookshelfLibrarySyncJob.new : AudiobookshelfLibrarySyncJob.new(**arguments)
    SolidQueue::Job.create!(
      active_job_id: active_job.job_id,
      class_name: "AudiobookshelfLibrarySyncJob",
      queue_name: "default",
      arguments: active_job.serialize,
      scheduled_at: scheduled_at
    )
  end

  def with_post_scan_refresh_cache
    Rails.cache.clear
    yield
  end
end
