# frozen_string_literal: true

require "test_helper"

class AudiobookshelfLibrarySyncJobTest < ActiveJob::TestCase
  setup do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")
    SettingsService.set(:audiobookshelf_audiobook_library_id, "lib-audio")
    SettingsService.set(:audiobookshelf_ebook_library_id, "")
    SettingsService.set(:audiobookshelf_library_sync_interval, 3600)
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
    [ manual, post_scan, recurring, claimed ].each do |preserved|
      assert SolidQueue::Job.exists?(preserved.id), "expected job #{preserved.id} to be preserved"
    end
  end

  test "scheduled syncs honor the configured interval on minute boundaries" do
    SettingsService.set(:audiobookshelf_library_sync_interval, 600)
    LibraryItem.destroy_all

    travel_to Time.zone.parse("2026-08-26 12:00:00") do
      LibraryItem.create!(
        title: "Test Book",
        author: "Test Author",
        external_id: "test-1",
        library_type: "audiobook",
        updated_at: 9.minutes.ago
      )

      job = AudiobookshelfLibrarySyncJob.new
      assert_not job.send(:sync_due?)

      LibraryItem.update_all(updated_at: 10.minutes.ago)
      assert job.send(:sync_due?)
    end
  end

  test "scheduled syncs run when no library items exist yet" do
    LibraryItem.destroy_all

    assert AudiobookshelfLibrarySyncJob.new.send(:sync_due?)
  end

  test "post-scan refresh enqueues a delayed one-shot sync" do
    clear_enqueued_jobs

    with_post_scan_refresh_cache do
      assert_enqueued_with(
        job: AudiobookshelfLibrarySyncJob,
        args: [],
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
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.clear
    yield
  ensure
    Rails.cache = previous
  end
end
