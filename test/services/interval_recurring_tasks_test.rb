# frozen_string_literal: true

require "test_helper"

class IntervalRecurringTasksTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  cover "IntervalRecurringTasks*"

  TASK_KEYS = %w[health_check audiobookshelf_library_sync].freeze

  setup do
    SolidQueue::Record.establish_connection(:queue)
    Setting.where(key: %w[health_check_interval audiobookshelf_library_sync_interval]).delete_all
    SolidQueue::RecurringTask.where(key: TASK_KEYS).delete_all
  end

  teardown do
    SolidQueue::RecurringTask.where(key: TASK_KEYS).delete_all
    Setting.where(key: %w[health_check_interval audiobookshelf_library_sync_interval]).delete_all
  end

  test "default intervals are not enqueued every minute" do
    config = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    %w[default production].each do |env_name|
      jobs = config.fetch(env_name)
      assert_nil jobs["health_check"], "#{env_name} still has a static health_check tick"
      assert_nil jobs["audiobookshelf_library_sync"], "#{env_name} still has a static library sync tick"
    end

    queue = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/queue.yml"))
    %w[development production].each do |env_name|
      assert_equal true, queue.dig(env_name, "scheduler", "dynamic_tasks_enabled"),
        "#{env_name} scheduler will not adopt interval changes"
    end

    assert_equal "every minute", config.dig("default", "download_monitor", "schedule")

    IntervalRecurringTasks.sync_all!

    health = task("health_check")
    sync = task("audiobookshelf_library_sync")

    assert_equal "every 5 minutes UTC", health.schedule
    assert_equal "every hour UTC", sync.schedule
    [ health, sync ].each do |recurring|
      assert_not recurring.static?
      assert_equal "default", recurring.queue_name
      assert_equal [ { scheduled: true } ], recurring.arguments
    end
    assert_equal "HealthCheckJob", health.class_name
    assert_equal "AudiobookshelfLibrarySyncJob", sync.class_name

    assert_operator minimum_gap(health), :>=, 5.minutes.to_i
    assert_operator minimum_gap(sync), :>=, 1.hour.to_i

    health_id = health.id
    sync_id = sync.id
    IntervalRecurringTasks.sync_all!
    assert_equal health_id, task("health_check").id
    assert_equal sync_id, task("audiobookshelf_library_sync").id
  end

  test "changing an interval replaces the recurring task so a running scheduler adopts it" do
    IntervalRecurringTasks.sync_all!
    health_id = task("health_check").id
    sync_id = task("audiobookshelf_library_sync").id

    SettingsService.set(:health_check_interval, 600)
    SettingsService.set(:audiobookshelf_library_sync_interval, 120)

    health = task("health_check")
    sync = task("audiobookshelf_library_sync")
    assert_equal "every 10 minutes UTC", health.schedule
    assert_equal "every 2 minutes UTC", sync.schedule
    assert_not_equal health_id, health.id
    assert_not_equal sync_id, sync.id
    assert_not health.static?
    assert_not sync.static?

    stable_id = health.id
    SettingsService.set(:health_check_interval, 600)
    assert_equal stable_id, task("health_check").id

    SettingsService.set(:audiobookshelf_library_sync_interval, 0)
    assert_nil SolidQueue::RecurringTask.find_by(key: "audiobookshelf_library_sync")

    SettingsService.set(:audiobookshelf_library_sync_interval, 3600)
    assert_equal "every hour UTC", task("audiobookshelf_library_sync").schedule
  end

  test "a static every-minute row left from an older install is replaced" do
    SolidQueue::RecurringTask.create!(
      key: "health_check",
      class_name: "HealthCheckJob",
      queue_name: "default",
      schedule: "every minute",
      static: true,
      arguments: [ { scheduled: true } ]
    )

    IntervalRecurringTasks.sync_all!

    health = task("health_check")
    assert_not health.static?
    assert_equal "every 5 minutes UTC", health.schedule
    assert_operator minimum_gap(health), :>=, 5.minutes.to_i
  end

  test "sub-day schedules do not fire before the interval elapses" do
    [ 60, 90, 120, 300, 420, 600, 2_400, 3_600, 5_400, 7_200, 86_399 ].each do |seconds|
      minutes = (seconds / 60.0).ceil
      expected = minutes * 60
      expression = IntervalRecurringTasks.schedule_for(seconds)
      cron = Fugit.parse(expression)
      assert_instance_of Fugit::Cron, cron, expression

      gap = minimum_cron_gap(cron)
      assert_operator gap, :<=, expected, "#{seconds}s -> #{expression} is coarser than the setting"
      assert_operator gap, :>=, 60, expression
      next if minutes >= 24 * 60

      from = Time.utc(2026, 6, 1)
      gaps = accepted_run_gaps(seconds, from: from, to: from + (expected * 4), late_by: 0)
      assert_equal [ expected ], gaps.uniq, "#{seconds}s -> #{expression}"
    end
  end

  test "intervals without an exact cron keep the requested cadence on a finer tick" do
    {
      31.minutes.to_i => "every minute UTC",
      75.minutes.to_i => "every 15 minutes UTC"
    }.each do |seconds, expression|
      assert_equal expression, IntervalRecurringTasks.schedule_for(seconds), "#{seconds}s"

      from = Time.utc(2026, 6, 1)
      gaps = accepted_run_gaps(seconds, from: from, to: from + (seconds * 4), late_by: 0)
      assert_equal [ seconds ], gaps.uniq, expression
    end

    assert IntervalRecurringTasks.due?(
      Time.utc(2026, 6, 1, 0, 1, 0),
      75.minutes.to_i,
      now: Time.utc(2026, 6, 1, 1, 15, 0)
    )
    assert_not IntervalRecurringTasks.due?(
      Time.utc(2026, 6, 1, 0, 1, 0),
      75.minutes.to_i,
      now: Time.utc(2026, 6, 1, 1, 0, 0)
    )
    assert IntervalRecurringTasks.due?(
      Time.utc(2026, 6, 1, 0, 0, 0),
      31.minutes.to_i,
      now: Time.utc(2026, 6, 1, 0, 31, 0)
    )
    assert_not IntervalRecurringTasks.due?(
      Time.utc(2026, 6, 1, 0, 0, 0),
      31.minutes.to_i,
      now: Time.utc(2026, 6, 1, 0, 30, 0)
    )
    assert IntervalRecurringTasks.due?(
      Time.utc(2026, 6, 1, 0, 1, 0),
      31.minutes.to_i,
      now: Time.utc(2026, 6, 1, 0, 32, 0)
    )
  end

  test "scheduler startup catch-up runs an overdue task and skips one that is not due" do
    with_memory_cache do
      SettingsService.set(:health_check_interval, 7.days.to_i)
      SettingsService.set(:audiobookshelf_library_sync_interval, 1.hour.to_i)

      travel_to Time.utc(2026, 11, 15, 12, 5, 0) do
        assert_no_enqueued_jobs only: [ HealthCheckJob, AudiobookshelfLibrarySyncJob ] do
          IntervalRecurringTasks.sync_all!
        end

        seed_health_checks(Time.utc(2026, 11, 8, 12, 1, 0))
        write_library_sync_at(Time.utc(2026, 11, 15, 12, 1, 0))

        assert_empty IntervalRecurringTasks.catch_up!
        assert_enqueued_with(job: HealthCheckJob, args: [ { scheduled: true } ])
        assert_enqueued_with(job: AudiobookshelfLibrarySyncJob, args: [ { scheduled: true } ])

        assert_equal 6, perform_caught_up_health_check
        assert_equal 0, perform_caught_up_library_sync

        clear_enqueued_jobs
        SettingsService.set(:audiobookshelf_library_sync_interval, 0)
        assert_no_enqueued_jobs only: AudiobookshelfLibrarySyncJob do
          assert_enqueued_jobs 1, only: HealthCheckJob do
            assert_empty IntervalRecurringTasks.catch_up!
          end
        end
      end
    end
  end

  test "a library sync interval below one minute still waits a full minute" do
    SettingsService.set(:audiobookshelf_library_sync_interval, 30)

    sync = task("audiobookshelf_library_sync")
    assert_equal "every minute UTC", sync.schedule
    assert_operator minimum_gap(sync), :>=, 1.minute.to_i
  end

  test "library sync reconciliation waits until the settings transaction commits" do
    IntervalRecurringTasks.sync_all!
    library_id = task("audiobookshelf_library_sync").id

    Setting.transaction do
      SettingsService.set(:audiobookshelf_library_sync_interval, 0)
      kept = SolidQueue::RecurringTask.find_by(key: "audiobookshelf_library_sync")
      assert_equal library_id, kept&.id, "reconciled before the settings transaction committed"
    end

    assert_nil SolidQueue::RecurringTask.find_by(key: "audiobookshelf_library_sync")
  end

  test "a rejected settings save keeps the library sync recurring task" do
    SettingsService.set(:health_check_interval, 600)
    SettingsService.set(:audiobookshelf_library_sync_interval, 3600)
    library_id = task("audiobookshelf_library_sync").id

    error = assert_raises(ArgumentError) do
      Setting.transaction do
        SettingsService.set(:audiobookshelf_library_sync_interval, 0)
        SettingsService.set(:health_check_interval, 30)
      end
    end

    assert_match(/at least 60/, error.message)
    assert_equal 3600, SettingsService.get(:audiobookshelf_library_sync_interval)
    assert_equal 600, SettingsService.get(:health_check_interval)
    kept = SolidQueue::RecurringTask.find_by(key: "audiobookshelf_library_sync")
    assert kept, "rolled-back settings save deleted the library sync task"
    assert_equal library_id, kept.id
    assert_equal "every hour UTC", kept.schedule
  end

  test "a seven day interval stays weekly across a month boundary" do
    gaps = accepted_run_gaps(7.days.to_i, from: Time.utc(2026, 1, 1), to: Time.utc(2026, 3, 15))

    assert_equal [ 7.days.to_i ], gaps.uniq
  end

  test "day intervals still tick on a day whose local midnight is skipped" do
    zone = ActiveSupport::TimeZone["America/Santiago"]

    with_env("TZ" => "America/Santiago") do
      Time.use_zone(zone) do
        from = at(zone, "2026-08-28 00:00:00")
        to = at(zone, "2026-09-25 00:00:00")
        [ 1, 7 ].each do |days|
          accepted = accepted_runs(days.days.to_i, from: from, to: to, late_by: 0)
          dates = accepted.map { |run| run.in_time_zone(zone).to_date }
          assert_equal days, dates.each_cons(2).map { |earlier, later| (later - earlier).to_i }.uniq.sole, "#{days} days"
          assert_includes dates, Date.new(2026, 9, 6) if days == 1
        end
      end
    end
  end

  test "day schedules stay on calendar slots across daylight saving time" do
    zone = ActiveSupport::TimeZone["America/New_York"]
    weekly = 7.days.to_i
    daily = 1.day.to_i
    every_two_days = 2.days.to_i

    with_env("TZ" => "America/New_York") do
      Time.use_zone(zone) do
        assert IntervalRecurringTasks.due?(at(zone, "2026-03-08 12:01:00"), weekly, now: at(zone, "2026-03-15 12:00:00"))
        assert_not IntervalRecurringTasks.due?(at(zone, "2026-03-15 12:01:00"), weekly, now: at(zone, "2026-03-15 12:02:00"))
        assert IntervalRecurringTasks.due?(at(zone, "2026-03-08 12:01:00"), daily, now: at(zone, "2026-03-09 12:00:00"))
        assert_not IntervalRecurringTasks.due?(at(zone, "2026-03-08 12:01:00"), every_two_days, now: at(zone, "2026-03-09 12:00:00"))
        assert IntervalRecurringTasks.due?(at(zone, "2026-03-08 12:01:00"), every_two_days, now: at(zone, "2026-03-10 12:00:00"))

        assert_not IntervalRecurringTasks.due?(at(zone, "2026-11-01 12:01:00"), daily, now: at(zone, "2026-11-01 15:00:00"))
        assert IntervalRecurringTasks.due?(at(zone, "2026-11-01 12:01:00"), daily, now: at(zone, "2026-11-02 12:00:00"))
        assert_not IntervalRecurringTasks.due?(at(zone, "2026-11-02 12:01:00"), daily, now: at(zone, "2026-11-02 23:59:00"))
        assert_not IntervalRecurringTasks.due?(at(zone, "2026-10-31 12:01:00"), every_two_days, now: at(zone, "2026-11-01 12:00:00"))
        assert IntervalRecurringTasks.due?(at(zone, "2026-10-31 12:01:00"), every_two_days, now: at(zone, "2026-11-02 12:00:00"))
        assert_not IntervalRecurringTasks.due?(at(zone, "2026-11-01 12:01:00"), weekly, now: at(zone, "2026-11-01 15:00:00"))
        assert IntervalRecurringTasks.due?(at(zone, "2026-11-01 12:01:00"), weekly, now: at(zone, "2026-11-08 12:00:00"))
        assert_not IntervalRecurringTasks.due?(at(zone, "2026-11-08 12:01:00"), weekly, now: at(zone, "2026-11-08 15:00:00"))
      end
    end
  end

  test "multi-day intervals keep their elapsed gap across a month boundary" do
    from = Time.utc(2026, 1, 1)
    to = Time.utc(2026, 3, 15)

    [ 2, 3, 6, 7, 8, 14 ].each do |days|
      seconds = days.days.to_i
      gaps = accepted_run_gaps(seconds, from: from, to: to)
      assert gaps.any?, "no runs for #{days} days"
      assert_equal [ seconds ], gaps.uniq, "#{days} days -> #{IntervalRecurringTasks.schedule_for(seconds)}"
    end
  end

  test "an interval of a day and an hour keeps its elapsed cadence instead of waiting two days" do
    assert_equal "every hour UTC", IntervalRecurringTasks.schedule_for(25.hours.to_i)
    assert_equal "every 12 hours UTC", IntervalRecurringTasks.schedule_for(36.hours.to_i)
    assert_equal "every minute UTC", IntervalRecurringTasks.schedule_for(1.day.to_i + 60)

    from = Time.utc(2026, 1, 30)
    [ 25.hours.to_i, 36.hours.to_i ].each do |seconds|
      [ 0, 1.minute ].each do |late_by|
        gaps = accepted_run_gaps(seconds, from: from, to: from + (seconds * 4), late_by: late_by)
        assert_equal [ seconds ], gaps.uniq, "#{seconds}s late by #{late_by}s"
      end
    end

    assert IntervalRecurringTasks.due?(
      Time.utc(2026, 6, 1, 0, 0, 0), 1.day.to_i + 60, now: Time.utc(2026, 6, 2, 0, 1, 0)
    )
    assert_not IntervalRecurringTasks.due?(
      Time.utc(2026, 6, 1, 0, 0, 0), 1.day.to_i + 60, now: Time.utc(2026, 6, 2, 0, 0, 0)
    )
  end

  test "elapsed intervals keep their spacing across daylight saving time" do
    zone = ActiveSupport::TimeZone["America/New_York"]

    with_env("TZ" => "America/New_York") do
      Time.use_zone(zone) do
        assert_equal "every day at noon America/New_York", IntervalRecurringTasks.schedule_for(1.day.to_i)
        assert_equal "every day at noon America/New_York", IntervalRecurringTasks.schedule_for(7.days.to_i)

        from = at(zone, "2026-03-06 12:00:00")
        [ 2.hours.to_i, 25.hours.to_i, 36.hours.to_i ].each do |seconds|
          gaps = accepted_run_gaps(seconds, from: from, to: from + (seconds * 5), late_by: 0)
          assert_equal [ seconds ], gaps.uniq, "#{seconds}s -> #{IntervalRecurringTasks.schedule_for(seconds)}"
        end
      end
    end
  end

  test "a catch-up one second before a tick is left to that tick, which then runs once" do
    with_memory_cache do
      SettingsService.set(:health_check_interval, 300)
      SettingsService.set(:audiobookshelf_library_sync_interval, 3600)
      IntervalRecurringTasks.sync_all!
      seed_health_checks(Time.utc(2026, 11, 14, 22, 0, 0))
      write_library_sync_at(Time.utc(2026, 11, 14, 22, 0, 0))

      travel_to Time.utc(2026, 11, 15, 0, 59, 59) do
        assert_no_enqueued_jobs only: [ HealthCheckJob, AudiobookshelfLibrarySyncJob ] do
          assert_empty IntervalRecurringTasks.catch_up!
        end
      end

      travel_to Time.utc(2026, 11, 15, 1, 0, 0) do
        assert_equal 6, run_scheduled_health_check
        assert_equal 1, run_scheduled_library_sync
      end

      travel_to Time.utc(2026, 11, 15, 1, 0, 30) do
        assert_equal 0, run_scheduled_health_check
        assert_equal 0, run_scheduled_library_sync
      end

      travel_to Time.utc(2026, 11, 15, 1, 5, 0) do
        assert_equal 6, run_scheduled_health_check
      end
    end
  end

  test "a catch-up shortly after a missed weekly tick still lets the following week run" do
    with_memory_cache do
      SettingsService.set(:health_check_interval, 7.days.to_i)
      IntervalRecurringTasks.sync_all!
      seed_health_checks(Time.utc(2026, 11, 1, 12, 0, 0))

      travel_to Time.utc(2026, 11, 15, 12, 1, 0) do
        assert_empty IntervalRecurringTasks.catch_up!
        assert_equal 6, perform_caught_up_health_check
      end

      travel_to Time.utc(2026, 11, 22, 12, 0, 0) do
        assert_equal 6, run_scheduled_health_check
      end
    end
  end

  test "a catch-up for a slot the scheduler already enqueued is not enqueued again" do
    SettingsService.set(:health_check_interval, 300)
    IntervalRecurringTasks.sync_all!
    adapter = ActiveJob::QueueAdapters::SolidQueueAdapter.new
    slot = Time.utc(2026, 11, 15, 0, 5, 0)

    HealthCheckJob.stub(:queue_adapter, adapter) do
      HealthCheckJob.stub(:queue_adapter_name, "solid_queue") do
        travel_to slot + 30.seconds do
          assert task("health_check").enqueue(at: slot)
          assert_empty IntervalRecurringTasks.catch_up!
        end
      end
    end

    assert_equal 1, SolidQueue::RecurringExecution.where(task_key: "health_check", run_at: slot).count
    assert_equal 1, SolidQueue::Job.where(class_name: "HealthCheckJob").count
  ensure
    SolidQueue::Job.where(class_name: "HealthCheckJob").destroy_all
  end

  test "loading the app under bin/jobs check registers scheduler hooks without touching the queue" do
    registered = []
    synced = false

    with_program_name("bin/jobs") do
      Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("development")) do
        IntervalRecurringTasks.stub(:sync_all!, ->(**) { synced = true }) do
          SolidQueue.stub(:on_scheduler_start, proc { |&hook| registered << [ :start, hook ] }) do
            SolidQueue.stub(:on_scheduler_stop, proc { |&hook| registered << [ :stop, hook ] }) do
              assert_no_enqueued_jobs do
                load Rails.root.join("config/initializers/interval_recurring_tasks.rb").to_s
              end
            end
          end
        end
      end
    end

    assert_not synced, "booting the app reconciled recurring tasks outside the scheduler"
    assert_equal %i[start stop], registered.map(&:first)
    assert SolidQueue::Scheduler.lifecycle_hooks[:start].any?
    assert SolidQueue::Scheduler.lifecycle_hooks[:stop].any?

    started = 0
    stopped = 0
    IntervalRecurringTasks.stub(:scheduler_started!, -> { started += 1 }) do
      IntervalRecurringTasks.stub(:scheduler_stopped!, -> { stopped += 1 }) do
        registered.each { |_event, hook| hook.call(nil) }
      end
    end
    assert_equal 1, started
    assert_equal 1, stopped
  end

  test "skip-recurring starts no scheduler, so the start hook never runs" do
    kinds = ->(**options) { SolidQueue::Configuration.new(**options).configured_processes.map(&:kind) }

    assert_includes kinds.call, :scheduler
    assert_not_includes kinds.call(skip_recurring: true), :scheduler
  end

  test "scheduler start reconciles, catches up and keeps reconciling from committed settings" do
    SettingsService.set(:health_check_interval, 600)

    travel_to Time.utc(2026, 11, 15, 0, 1, 0) do
      assert_enqueued_jobs 2, only: [ HealthCheckJob, AudiobookshelfLibrarySyncJob ] do
        IntervalRecurringTasks.scheduler_started!(reconcile_every: 0.05)
      end
    end
    assert IntervalRecurringTasks.reconciling?
    assert_empty IntervalRecurringTasks.pending_catch_ups
    assert_equal "every 10 minutes UTC", task("health_check").schedule

    SolidQueue::RecurringTask.stub(:transaction, failing_queue_lock) do
      SettingsService.set(:health_check_interval, 900)
    end
    wait_for { SolidQueue::RecurringTask.find_by(key: "health_check")&.schedule == "every 15 minutes UTC" }
  ensure
    IntervalRecurringTasks.scheduler_stopped!
    assert_not IntervalRecurringTasks.reconciling?
  end

  test "a queue lock at scheduler start still starts the reconciler, which retries the catch-up" do
    SettingsService.set(:health_check_interval, 600)

    SolidQueue::RecurringTask.stub(:transaction, failing_queue_lock) do
      SolidQueue::RecurringTask.stub(:dynamic, failing_queue_lock) do
        SettingsService.set(:health_check_interval, 900)
        assert_no_enqueued_jobs only: [ HealthCheckJob, AudiobookshelfLibrarySyncJob ] do
          IntervalRecurringTasks.scheduler_started!(reconcile_every: 60)
        end
      end
    end
    assert IntervalRecurringTasks.reconciling?
    assert_equal IntervalRecurringTasks::TASKS.keys, IntervalRecurringTasks.pending_catch_ups
    assert_equal "every 10 minutes UTC", task("health_check").schedule

    IntervalRecurringTasks.reconciler.run

    assert_equal "every 15 minutes UTC", task("health_check").schedule
    assert_empty IntervalRecurringTasks.pending_catch_ups
  ensure
    IntervalRecurringTasks.scheduler_stopped!
  end

  test "a queue lock during the after-commit sync keeps the save and the next reconciliation applies it" do
    IntervalRecurringTasks.sync_all!
    stale_id = task("health_check").id

    SolidQueue::RecurringTask.stub(:transaction, failing_queue_lock) do
      assert_equal 600, SettingsService.set(:health_check_interval, 600)
      assert RemoteResult.failed?(IntervalRecurringTasks.reconcile!)
    end

    assert_equal 600, SettingsService.get(:health_check_interval)
    assert_equal stale_id, task("health_check").id
    assert_equal "every 5 minutes UTC", task("health_check").schedule

    assert_equal true, IntervalRecurringTasks.reconcile!
    assert_equal "every 10 minutes UTC", task("health_check").schedule
  end

  test "the queue write lock is taken before the interval is read" do
    SettingsService.set(:health_check_interval, 600)
    queue = SolidQueue::RecurringTask.connection
    events = []
    read = SettingsService.method(:get)
    record_queue_statement = lambda do |*, payload|
      next unless payload[:connection].equal?(queue) && payload[:name] != "SCHEMA"

      events << (payload[:sql].match?(/\A\s*(BEGIN|SAVEPOINT)/i) ? :queue_lock : :queue_statement)
    end

    SolidQueue::RecurringTask.cache do
      SolidQueue::RecurringTask.find_by(key: "health_check")
      ActiveSupport::Notifications.subscribed(record_queue_statement, "sql.active_record") do
        SettingsService.stub(:get, ->(key, **options) {
          events << :interval_read if key.to_sym == :health_check_interval
          read.call(key, **options)
        }) do
          IntervalRecurringTasks.sync_setting!(:health_check_interval)
        end
      end
    end

    assert_equal :queue_lock, events.first, "interval read before the queue transaction took its lock"
    assert_includes events, :interval_read
    assert_operator events.index(:queue_statement), :<, events.index(:interval_read)
    assert_equal "every 10 minutes UTC", task("health_check").schedule
  end

  test "a catch-up stays pending while the recurring row lags the committed interval" do
    SettingsService.set(:health_check_interval, 1.hour.to_i)
    SolidQueue::RecurringTask.stub(:transaction, failing_queue_lock) do
      SettingsService.set(:health_check_interval, 7.days.to_i)
    end
    assert_equal "every hour UTC", task("health_check").schedule

    travel_to Time.utc(2026, 11, 15, 12, 45, 0) do
      assert_no_enqueued_jobs only: HealthCheckJob do
        assert_includes IntervalRecurringTasks.catch_up!(%w[health_check]), "health_check"
      end

      assert_equal true, IntervalRecurringTasks.reconcile!
      assert_enqueued_jobs 1, only: HealthCheckJob do
        assert_empty IntervalRecurringTasks.catch_up!(%w[health_check])
      end
    end
  end

  test "a scheduler that starts within the second of a tick catches that tick up" do
    SettingsService.set(:health_check_interval, 300)
    IntervalRecurringTasks.sync_all!

    travel_to Time.utc(2026, 11, 15, 0, 5, 0) + 0.4 do
      assert_enqueued_jobs 1, only: HealthCheckJob do
        assert_empty IntervalRecurringTasks.catch_up!(%w[health_check])
      end
    end
  end

  test "a stopped scheduler's reconciler cannot clear the next scheduler's pending catch-ups" do
    SettingsService.set(:health_check_interval, 600)
    executor = Rails.application.executor
    old = IntervalRecurringTasks::Reconciler.new(interval: 60, executor: executor)
    replacement = IntervalRecurringTasks::Reconciler.new(interval: 60, executor: executor)

    SolidQueue::RecurringTask.stub(:dynamic, failing_queue_lock) do
      replacement.run
    end
    old.run

    assert_empty old.pending_catch_ups
    assert_equal IntervalRecurringTasks::TASKS.keys, replacement.pending_catch_ups
  ensure
    old&.stop
    replacement&.stop
  end

  private

  def at(zone, text)
    zone.parse(text)
  end

  def task(key)
    SolidQueue::RecurringTask.find_by!(key: key)
  end

  def minimum_gap(recurring_task)
    minimum_cron_gap(Fugit.parse(recurring_task.schedule))
  end

  def minimum_cron_gap(cron)
    cron_gaps(cron, Time.utc(2026, 1, 1, 0, 0, 0), Time.utc(2026, 1, 1, 0, 0, 0) + 3.days).min
  end

  def cron_gaps(cron, from, to)
    cursor = from
    gaps = []
    while (nxt = cron.next_time(cursor).to_t) < to
      gaps << (nxt - cursor).round if cursor > from
      cursor = nxt
    end
    gaps
  end

  def seed_health_checks(checked_at)
    SystemHealth.delete_all
    SystemHealth::SERVICES.each do |service|
      SystemHealth.create!(
        service: service,
        status: :healthy,
        last_check_at: checked_at,
        message: "ok"
      )
    end
  end

  def write_library_sync_at(time)
    Rails.cache.write(AudiobookshelfLibrarySyncJob::LAST_SCHEDULED_ATTEMPT_AT_CACHE_KEY, time)
  end

  def run_scheduled_health_check(job = HealthCheckJob.new(scheduled: true))
    checks = 0
    %i[
      check_indexer
      check_download_clients
      check_download_paths
      check_output_paths
      check_audiobookshelf
      check_hardcover
    ].each do |name|
      job.define_singleton_method(name) do
        checks += 1
        SystemHealth.update_all(last_check_at: Time.current)
      end
    end
    job.perform_now
    checks
  end

  def run_scheduled_library_sync(job = AudiobookshelfLibrarySyncJob.new(scheduled: true))
    syncs = 0
    service = Object.new
    service.define_singleton_method(:sync!) { syncs += 1 }
    LibraryPlatformClient.stub(:configured?, true) do
      AudiobookshelfLibrarySyncService.stub(:new, service) do
        job.perform_now
      end
    end
    syncs
  end

  def perform_caught_up_health_check
    run_scheduled_health_check(caught_up_job(HealthCheckJob))
  end

  def perform_caught_up_library_sync
    run_scheduled_library_sync(caught_up_job(AudiobookshelfLibrarySyncJob))
  end

  def caught_up_job(job_class)
    payload = enqueued_jobs.reverse.find { |job| job[:job] == job_class || job["job_class"] == job_class.name }
    assert payload, "no #{job_class} catch-up was enqueued"
    ActiveJob::Base.deserialize(payload)
  end

  def with_memory_cache
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original_cache
  end

  def with_program_name(name)
    original = $PROGRAM_NAME
    $PROGRAM_NAME = name
    yield
  ensure
    $PROGRAM_NAME = original
  end

  def wait_for(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      Thread.pass
      sleep 0.02
    end
  end

  def failing_queue_lock
    proc { |*| raise ActiveRecord::StatementTimeout, "SQLite3::BusyException: database is locked" }
  end

  def accepted_run_gaps(interval_seconds, **window)
    accepted_runs(interval_seconds, **window).each_cons(2).map { |earlier, later| (later - earlier).round }
  end

  def accepted_runs(interval_seconds, from:, to:, late_by: 1.minute)
    SettingsService.set(:audiobookshelf_library_sync_interval, interval_seconds)
    cron = Fugit.parse(IntervalRecurringTasks.schedule_for(interval_seconds))
    last_run = nil
    accepted = []
    cursor = from
    job = AudiobookshelfLibrarySyncJob.new
    cache = ActiveSupport::Cache::MemoryStore.new
    original_cache = Rails.cache
    Rails.cache = cache
    while (tick = cron.next_time(cursor).to_t) < to
      due = travel_to(tick) do
        if last_run
          cache.write(AudiobookshelfLibrarySyncJob::LAST_SCHEDULED_ATTEMPT_AT_CACHE_KEY, last_run)
        else
          cache.delete(AudiobookshelfLibrarySyncJob::LAST_SCHEDULED_ATTEMPT_AT_CACHE_KEY)
        end
        job.send(:sync_due?)
      end
      if due
        accepted << tick
        last_run = tick + late_by
      end
      cursor = tick
    end
    accepted
  ensure
    Rails.cache = original_cache if original_cache
  end
end
