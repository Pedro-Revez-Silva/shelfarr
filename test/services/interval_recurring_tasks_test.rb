# frozen_string_literal: true

require "test_helper"

class IntervalRecurringTasksTest < ActiveSupport::TestCase
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

    assert_equal "every 5 minutes", health.schedule
    assert_equal "every hour", sync.schedule
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

    initializer = Rails.root.join("config/initializers/interval_recurring_tasks.rb").read
    assert_match(/IntervalRecurringTasks\.sync_all!/, initializer)
    assert_match(/Rails\.env\.test\?/, initializer)
  end

  test "changing an interval replaces the recurring task so a running scheduler adopts it" do
    IntervalRecurringTasks.sync_all!
    health_id = task("health_check").id
    sync_id = task("audiobookshelf_library_sync").id

    SettingsService.set(:health_check_interval, 600)
    SettingsService.set(:audiobookshelf_library_sync_interval, 120)

    health = task("health_check")
    sync = task("audiobookshelf_library_sync")
    assert_equal "every 10 minutes", health.schedule
    assert_equal "every 2 minutes", sync.schedule
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
    assert_equal "every hour", task("audiobookshelf_library_sync").schedule
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
    assert_equal "every 5 minutes", health.schedule
    assert_operator minimum_gap(health), :>=, 5.minutes.to_i
  end

  test "sub-day schedules do not fire before the interval elapses" do
    [ 60, 90, 120, 300, 420, 600, 2_400, 3_600, 5_400, 7_200, 86_399 ].each do |seconds|
      expression = IntervalRecurringTasks.schedule_for(seconds)
      cron = Fugit.parse(expression)
      assert_instance_of Fugit::Cron, cron, expression

      gap = minimum_cron_gap(cron)
      expected = (seconds / 60.0).ceil * 60
      assert_operator gap, :>=, expected, "#{seconds}s -> #{expression} (#{gap.inspect})"
      assert_operator gap, :<=, expected + (expected / 2.0),
        "#{seconds}s -> #{expression} is coarser than the setting"
    end
  end

  test "a library sync interval below one minute still waits a full minute" do
    SettingsService.set(:audiobookshelf_library_sync_interval, 30)

    sync = task("audiobookshelf_library_sync")
    assert_equal "every minute", sync.schedule
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
    assert_equal "every hour", kept.schedule
  end

  test "a seven day interval stays weekly across a month boundary" do
    expression = IntervalRecurringTasks.schedule_for(7.days.to_i)
    gaps = cron_gaps(Fugit.parse(expression), Time.utc(2026, 1, 1), Time.utc(2026, 3, 15))

    assert_equal [ 7.days.to_i ], gaps.uniq, expression
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

  private

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

  # A minute after the slot is a worker that started late.
  def accepted_run_gaps(interval_seconds, from:, to:)
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
        last_run = tick + 1.minute
      end
      cursor = tick
    end
    accepted.each_cons(2).map { |earlier, later| (later - earlier).round }
  ensure
    Rails.cache = original_cache if original_cache
  end
end
