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

  test "a claimed scheduler lease survives concurrency maintenance past 10 minutes" do
    SolidQueue::Record.establish_connection(:queue)
    key = HardcoverSyncSchedulerJob.new.concurrency_key
    assert_includes AudiobookshelfLibrarySyncJob::ConcurrencyLease::KEYS, key
    assert_includes AudiobookshelfLibrarySyncJob::ConcurrencyLease::KEYS, AudiobookshelfLibrarySyncJob.new.concurrency_key

    process = SolidQueue::Process.register(
      kind: "Worker",
      name: "scheduler-lease-#{SecureRandom.hex(4)}",
      pid: Process.pid,
      hostname: "test",
      metadata: {}
    )
    active_job = HardcoverSyncSchedulerJob.new
    job = SolidQueue::Job.create!(
      active_job_id: active_job.job_id,
      class_name: "HardcoverSyncSchedulerJob",
      queue_name: "default",
      arguments: active_job.serialize,
      concurrency_key: key,
      scheduled_at: Time.current
    )
    SolidQueue::ClaimedExecution.create!(job: job, process: process)
    SolidQueue::Semaphore.where(key: key).delete_all
    SolidQueue::Semaphore.create!(key: key, value: 0, expires_at: Time.current)

    leap = [ HardcoverSyncSchedulerJob.concurrency_duration + 5.seconds, 10.minutes + 5.seconds ].max
    assert_operator leap, :>, 10.minutes
    travel leap do
      SolidQueue::Dispatcher::ConcurrencyMaintenance.new(5.minutes, 500).send(:expire_semaphores)
      assert SolidQueue::Semaphore.exists?(key: key)
    end
  ensure
    if defined?(job) && job
      SolidQueue::ClaimedExecution.where(job_id: job.id).delete_all
      job.delete
    end
    process&.destroy
    SolidQueue::Semaphore.where(key: key).delete_all if defined?(key) && key
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

class AudiobookshelfLibrarySyncOverlapTest < ActiveJob::TestCase
  self.use_transactional_tests = false

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
    restore_test_adapter!
    Rails.cache = @original_cache
  end

  test "a second sync does not enter the library request after the concurrency lease" do
    LibraryItem.where(audiobookshelf_id: "ab-keep").delete_all
    LibraryItem.create!(
      library_platform: "audiobookshelf",
      library_id: "lib-audio",
      audiobookshelf_id: "ab-keep",
      title: "Kept Title",
      missing: false
    )
    entered = Queue.new
    release = Queue.new
    gate = Mutex.new
    inside = 0
    max_inside = 0

    VCR.turned_off do
      stub_request(:get, %r{/api/libraries/lib-audio/items}).to_return do
        gate.synchronize do
          inside += 1
          max_inside = inside if inside > max_inside
        end
        entered << true
        release.pop
        gate.synchronize { inside -= 1 }
        {
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "results" => [ { "id" => "ab-keep", "title" => "Kept Title", "author" => "Keeper" } ],
            "total" => 1
          }.to_json
        }
      end

      with_claimed_syncs(release) do |process|
        AudiobookshelfLibrarySyncJob.perform_later
        start_ready_syncs(process)
        wait_for("the first sync to enter the library request") { !entered.empty? }

        AudiobookshelfLibrarySyncJob.perform_later
        wait_for("the second sync to block on the lease") { blocked_sync? }

        leap = [ AudiobookshelfLibrarySyncJob.concurrency_duration + 5.seconds, 10.minutes + 5.seconds ].max
        assert_operator leap, :>, 10.minutes
        travel leap do
          key = AudiobookshelfLibrarySyncJob.new.concurrency_key
          assert SolidQueue::Semaphore.where(key: key).where(expires_at: ...Time.current).exists?
          maintenance = SolidQueue::Dispatcher::ConcurrencyMaintenance.new(5.minutes, 500)
          maintenance.send(:expire_semaphores)
          maintenance.send(:unblock_blocked_executions)
          if start_ready_syncs(process)
            wait_for("a released sync to enter the library request") { entered.size > 1 }
          end
          assert_equal 1, gate.synchronize { max_inside }
          assert blocked_sync?
        end
      end
    end

    assert_equal 1, gate.synchronize { max_inside }
    assert_equal "Kept Title", LibraryItem.find_by(audiobookshelf_id: "ab-keep")&.title
    assert_instance_of ActiveJob::QueueAdapters::TestAdapter, ActiveJob::Base.queue_adapter
    assert_no_enqueued_jobs
  ensure
    release_syncs(release, 2) if defined?(release) && release
    join_sync_threads
    restore_test_adapter!
    LibraryItem.where(audiobookshelf_id: "ab-keep").delete_all
  end

  private

  def with_claimed_syncs(release)
    process = nil
    original_config = SolidQueue::Record.connection_db_config
    SolidQueue::Record.establish_connection(:queue)
    switch_to_solid_queue!
    clear_sync_queue!
    @sync_threads = []
    @sync_thread_error = nil
    process = SolidQueue::Process.register(
      kind: "Worker",
      name: "library-sync-#{SecureRandom.hex(4)}",
      pid: Process.pid,
      hostname: "test",
      metadata: {}
    )
    yield process
  ensure
    begin
      release_syncs(release, 2)
      join_sync_threads
      start_ready_syncs(process) if process
      join_sync_threads
      clear_sync_queue! if process
      process&.deregister
    ensure
      SolidQueue::Record.establish_connection(original_config) if original_config
      restore_test_adapter!
    end
    raise @sync_thread_error if @sync_thread_error && !$!
  end

  def switch_to_solid_queue!
    return if @switched_adapter

    @original_queue_adapter = ActiveJob::Base._queue_adapter
    @original_test_adapter = ActiveJob::Base._test_adapter
    @switched_adapter = true
    ActiveJob::Base.disable_test_adapter
    ActiveJob::Base.queue_adapter = :solid_queue
  end

  def restore_test_adapter!
    return unless @switched_adapter

    if @original_queue_adapter
      ActiveJob::Base.queue_adapter = @original_queue_adapter
    else
      ActiveJob::Base.queue_adapter = :test
    end
    if @original_test_adapter
      ActiveJob::Base.enable_test_adapter(@original_test_adapter)
    else
      ActiveJob::Base.disable_test_adapter
    end
    @switched_adapter = false
  end

  def start_ready_syncs(process)
    return false unless process

    claimed = SolidQueue::ReadyExecution.claim("*", 5, process.id)
    return false if claimed.empty?

    claimed.each do |execution|
      @sync_threads << Thread.new(execution) do |claimed_execution|
        Thread.current.report_on_exception = false
        Thread.current.abort_on_exception = false
        claimed_execution.perform
      rescue Exception => error
        @sync_thread_error = error
      end
    end
    true
  end

  def join_sync_threads
    @sync_threads&.each(&:join)
  end

  def release_syncs(release, count)
    return unless release

    count.times { release << true }
  end

  def clear_sync_queue!
    SolidQueue::Job.uncached do
      jobs = SolidQueue::Job.where(class_name: "AudiobookshelfLibrarySyncJob")
      ids = jobs.ids
      if ids.any?
        SolidQueue::BlockedExecution.where(job_id: ids).delete_all
        SolidQueue::ClaimedExecution.where(job_id: ids).delete_all
        SolidQueue::ReadyExecution.where(job_id: ids).delete_all
        SolidQueue::FailedExecution.where(job_id: ids).delete_all
        SolidQueue::ScheduledExecution.where(job_id: ids).delete_all
        jobs.delete_all
      end
      SolidQueue::Semaphore.where(key: AudiobookshelfLibrarySyncJob.new.concurrency_key).delete_all
    end
  end

  def blocked_sync?
    SolidQueue::BlockedExecution.uncached do
      SolidQueue::BlockedExecution.joins(:job)
        .where(solid_queue_jobs: { class_name: "AudiobookshelfLibrarySyncJob" })
        .exists?
    end
  end

  def wait_for(description)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until yield
      detail = SolidQueue::FailedExecution.joins(:job)
        .where(solid_queue_jobs: { class_name: "AudiobookshelfLibrarySyncJob" })
        .pluck(:error)
        .join("\n")
      raise "timed out waiting for #{description}\n#{detail}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.02
    end
  end
end
