# frozen_string_literal: true

require "test_helper"

class IntervalRecurringTasksTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    SolidQueue::Record.establish_connection(:queue)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    SystemHealth.delete_all
    SettingsService.set(:health_check_interval, 300)
    SettingsService.set(:audiobookshelf_library_sync_interval, 3600)
  end

  teardown do
    IntervalRecurringTasks.stop!
    Rails.cache = @original_cache
  end

  test "checks elapsed time without enqueueing an idle minute job" do
    last_check = Time.utc(2026, 11, 15, 12, 4, 0)
    set_last_health_check(last_check)
    Rails.cache.write(AudiobookshelfLibrarySyncJob::LAST_SCHEDULED_ATTEMPT_AT_CACHE_KEY, last_check)

    LibraryPlatformClient.stub(:configured?, true) do
      travel_to last_check + 1.minute do
        assert_no_enqueued_jobs { IntervalRecurringTasks.poll! }
      end

      travel_to last_check + 5.minutes do
        assert_enqueued_with(job: HealthCheckJob, args: [ { scheduled: true } ]) do
          assert_no_enqueued_jobs(only: AudiobookshelfLibrarySyncJob) { IntervalRecurringTasks.poll! }
        end
      end
    end
  end

  test "a committed shorter interval becomes due on the next poll" do
    last_check = Time.utc(2026, 11, 15, 10, 0, 0)
    set_last_health_check(last_check)
    SettingsService.set(:health_check_interval, 2.hours.to_i)

    travel_to last_check + 1.hour - 1.second do
      assert_no_enqueued_jobs(only: HealthCheckJob) { IntervalRecurringTasks.poll! }
      SettingsService.set(:health_check_interval, 1.hour.to_i)
    end
    travel_to last_check + 1.hour + 1.second do
      assert_enqueued_jobs(1, only: HealthCheckJob) { IntervalRecurringTasks.poll! }
    end
  end

  test "library sync honors an elapsed interval longer than a day and stops when disabled" do
    last_sync = Time.utc(2026, 3, 29, 0, 59, 0)
    Rails.cache.write(AudiobookshelfLibrarySyncJob::LAST_SCHEDULED_ATTEMPT_AT_CACHE_KEY, last_sync)
    SettingsService.set(:audiobookshelf_library_sync_interval, 25.hours.to_i)

    LibraryPlatformClient.stub(:configured?, true) do
      travel_to last_sync + 25.hours - 1.minute do
        assert_no_enqueued_jobs(only: AudiobookshelfLibrarySyncJob) { IntervalRecurringTasks.poll! }
      end
      travel_to last_sync + 25.hours do
        assert_enqueued_with(job: AudiobookshelfLibrarySyncJob, args: [ { scheduled: true } ]) do
          IntervalRecurringTasks.poll!
        end
      end
      SettingsService.set(:audiobookshelf_library_sync_interval, 0)
      travel_to last_sync + 25.hours do
        assert_no_enqueued_jobs(only: AudiobookshelfLibrarySyncJob) { IntervalRecurringTasks.poll! }
      end
    end
  end

  test "an unconfigured library platform has no automatic sync work" do
    LibraryPlatformClient.stub(:configured?, false) do
      assert_no_enqueued_jobs(only: AudiobookshelfLibrarySyncJob) { IntervalRecurringTasks.poll! }
    end
  end

  test "scheduler startup honors custom recurring tasks without requiring dynamic tasks" do
    custom_task = SolidQueue::RecurringTask.from_configuration(
      "health_check", class: "HealthCheckJob", schedule: "every hour"
    )
    scheduler = SolidQueue::Scheduler.new(recurring_tasks: [ custom_task ], dynamic_tasks_enabled: false)

    LibraryPlatformClient.stub(:configured?, true) do
      assert_no_enqueued_jobs(only: HealthCheckJob) do
        assert_enqueued_jobs(1, only: AudiobookshelfLibrarySyncJob) do
          scheduler.send(:run_start_hooks)
        end
      end
    end
  end

  test "the scheduler is absent when the recurring configuration is disabled" do
    assert_not_includes SolidQueue::Configuration.new.configured_processes.map(&:kind), :scheduler
    assert_not_includes SolidQueue::Configuration.new(skip_recurring: true).configured_processes.map(&:kind), :scheduler
  end

  test "a queue lock leaves due work eligible for the next poll" do
    real_transaction = SolidQueue::Job.method(:transaction)
    attempts = 0
    transaction = lambda do |&block|
      attempts += 1
      raise ActiveRecord::StatementTimeout, "queue is locked" if attempts == 1

      real_transaction.call(&block)
    end

    LibraryPlatformClient.stub(:configured?, true) do
      SolidQueue::Job.stub(:transaction, transaction) do
        assert_no_enqueued_jobs(only: HealthCheckJob) do
          assert_enqueued_jobs(1, only: AudiobookshelfLibrarySyncJob) { IntervalRecurringTasks.poll! }
        end
      end
    end
    assert_enqueued_jobs(1, only: HealthCheckJob) { IntervalRecurringTasks.poll!(%w[health_check]) }
  end

  test "Solid Queue records one run per minute and suppresses jobs that are still pending" do
    adapter = ActiveJob::QueueAdapters::SolidQueueAdapter.new
    slot = Time.utc(2026, 11, 15, 0, 5, 0)
    jobs = SolidQueue::Job.where(class_name: "HealthCheckJob")

    HealthCheckJob.stub(:queue_adapter_name, "solid_queue") do
      HealthCheckJob.stub(:queue_adapter, adapter) do
        travel_to slot do
          assert_difference -> { jobs.count }, 1 do
            2.times { IntervalRecurringTasks.poll!(%w[health_check]) }
          end
          assert SolidQueue::RecurringExecution.exists?(task_key: "health_check", run_at: slot)
          jobs.update_all(finished_at: slot)
          assert_no_difference -> { jobs.count } do
            IntervalRecurringTasks.poll!(%w[health_check])
          end
          jobs.update_all(finished_at: nil)
        end

        travel_to slot + 1.minute do
          assert_no_difference -> { jobs.count } do
            IntervalRecurringTasks.poll!(%w[health_check])
          end
        end
      end
    end
  ensure
    jobs&.destroy_all
  end

  private

  def set_last_health_check(time)
    SystemHealth::SERVICES.each do |service|
      SystemHealth.create!(service: service, status: :healthy, last_check_at: time, message: "ok")
    end
  end
end
