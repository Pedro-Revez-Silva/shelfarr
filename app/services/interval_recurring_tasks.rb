# frozen_string_literal: true

require "fugit"

class IntervalRecurringTasks
  DAY_MINUTES = 24 * 60
  RECONCILE_INTERVAL = 60
  ELAPSED_ZONE = "UTC"

  TASKS = {
    "health_check" => {
      job_class: "HealthCheckJob",
      setting: :health_check_interval,
      minimum_seconds: SettingsService::MIN_HEALTH_CHECK_INTERVAL
    }.freeze,
    "audiobookshelf_library_sync" => {
      job_class: "AudiobookshelfLibrarySyncJob",
      setting: :audiobookshelf_library_sync_interval,
      minimum_seconds: 60,
      disable_when_non_positive: true
    }.freeze
  }.freeze

  class Reconciler
    attr_reader :pending_catch_ups

    def initialize(interval:, executor:, dynamic_tasks_enabled: true)
      @executor = executor
      @dynamic_tasks_enabled = dynamic_tasks_enabled
      @pending_catch_ups = TASKS.keys
      @timer = Concurrent::TimerTask.new(execution_interval: interval) { run }
    end

    def start
      run(startup: true)
    ensure
      @timer.execute
    end

    def run(startup: false)
      @executor.wrap do
        IntervalRecurringTasks.reconcile!
        if @dynamic_tasks_enabled || startup
          @pending_catch_ups = IntervalRecurringTasks.catch_up!(@pending_catch_ups)
        else
          IntervalRecurringTasks.catch_up!(nearest: false)
        end
      end
    end

    def stop
      @timer.shutdown
    end

    def running?
      @timer.running?
    end
  end

  class << self
    attr_reader :reconciler

    def sync_all!(replace_static: true)
      TASKS.each_key { |key| sync_task!(key, replace_static:) }
    end

    def sync_setting!(setting_key)
      setting_key = setting_key.to_sym
      key = TASKS.each_key.find { |task_key| TASKS.fetch(task_key)[:setting] == setting_key }
      sync_task!(key, replace_static: false) if key
    end

    def reconcile!(replace_static: false)
      sync_all!(replace_static:)
      true
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.warn "[Shelfarr] Interval recurring tasks were not reconciled: #{error.message}"
      RemoteResult::Failed.new(error)
    end

    def reconcile_setting!(setting_key)
      sync_setting!(setting_key)
      true
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.warn "[Shelfarr] #{setting_key} schedule waits for the next reconciliation: #{error.message}"
      RemoteResult::Failed.new(error)
    end

    def scheduler_started!(dynamic_tasks_enabled: true, reconcile_every: RECONCILE_INTERVAL, executor: Rails.application.executor)
      scheduler_stopped!
      @reconciler = Reconciler.new(interval: reconcile_every, executor:, dynamic_tasks_enabled:)
      @reconciler.start
    end

    def scheduler_stopped!
      @reconciler&.stop
      @reconciler = nil
    end

    def reconciling?
      @reconciler&.running? || false
    end

    def pending_catch_ups
      @reconciler&.pending_catch_ups || []
    end

    def catch_up!(keys = TASKS.keys, now: Time.current, nearest: true)
      keys.select { |key| still_missed?(catch_up_task(key, now, nearest:)) }
    end

    def schedule_for(interval_seconds)
      minutes = interval_minutes(interval_seconds)
      expression = expression_for(minutes)
      parsed = Fugit.parse(expression)
      unless parsed.is_a?(Fugit::Cron)
        raise ArgumentError, "unsupported recurring schedule #{expression.inspect}"
      end

      expression
    end

    def due?(last_at, interval_seconds, now: Time.current)
      return true unless last_at.respond_to?(:beginning_of_minute)

      seconds = [ interval_seconds.to_i, 60 ].max
      last_minute = last_at.beginning_of_minute
      now_minute = now.beginning_of_minute
      return false if now_minute <= last_minute

      previous_slot = schedule_slot(last_minute, seconds)
      current_slot = schedule_slot(now_minute, seconds)
      minutes = interval_minutes(seconds)
      if whole_days?(minutes)
        calendar_days_between(previous_slot, current_slot) >= minutes / DAY_MINUTES
      else
        current_slot >= previous_slot + minutes.minutes
      end
    end

    private

    def still_missed?(result)
      RemoteResult.failed?(result) || !result
    end

    def catch_up_task(key, now, nearest:)
      config = TASKS.fetch(key)
      schedule = desired_schedule(config)
      return true if schedule.nil?

      task = SolidQueue::RecurringTask.find_by(key: key)
      return true if task&.static?
      return false unless same_task?(task, key, task_options(config, schedule))

      slot = missed_slot(task.schedule, now, nearest:)
      return true if slot.nil? || SolidQueue::RecurringExecution.exists?(task_key: key, run_at: slot)

      task.enqueue(at: slot) || SolidQueue::RecurringExecution.exists?(task_key: key, run_at: slot)
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.warn "[Shelfarr] #{key} catch-up will be retried: #{error.message}"
      RemoteResult::Failed.new(error)
    end

    def missed_slot(schedule, now, nearest:)
      cron = Fugit.parse(schedule)
      missed = cron.previous_time(now.change(usec: 0) + 1.second).to_t
      return missed unless nearest

      upcoming = cron.next_time(now).to_t
      missed if now - missed < upcoming - now
    end

    def sync_task!(key, replace_static:)
      attempts = 0
      begin
        attempts += 1
        write_task!(key, replace_static:)
      rescue ActiveRecord::RecordNotUnique
        retry if attempts < 3
        raise
      end
    end

    def write_task!(key, replace_static:)
      config = TASKS.fetch(key)

      SolidQueue::RecurringTask.transaction do
        existing = SolidQueue::RecurringTask.uncached { SolidQueue::RecurringTask.find_by(key: key) }
        next if existing&.static? && !replace_static

        schedule = Setting.uncached { desired_schedule(config) }
        if schedule.nil?
          existing&.destroy!
          next
        end

        options = task_options(config, schedule)
        next if same_task?(existing, key, options)

        existing&.destroy!
        SolidQueue.schedule_recurring_task(key, **options)
      end
    end

    def desired_schedule(config)
      interval = SettingsService.get(config[:setting]).to_i
      return nil if config[:disable_when_non_positive] && interval <= 0

      schedule_for([ interval, config[:minimum_seconds] ].max)
    end

    def task_options(config, schedule)
      {
        class: config[:job_class],
        queue: "default",
        args: [ { scheduled: true } ],
        schedule: schedule
      }
    end

    def same_task?(existing, key, options)
      return false if existing.nil? || existing.static?

      desired = SolidQueue::RecurringTask.from_configuration(key, **options, static: false)
      existing.class_name == desired.class_name &&
        existing.queue_name == desired.queue_name &&
        existing.schedule == desired.schedule &&
        SolidQueue::RecurringTask::Arguments.dump(existing.arguments) ==
          SolidQueue::RecurringTask::Arguments.dump(desired.arguments)
    end

    def interval_minutes(interval_seconds)
      [ interval_seconds.to_i, 60 ].max.ceildiv(60)
    end

    def whole_days?(minutes)
      minutes >= DAY_MINUTES && (minutes % DAY_MINUTES).zero?
    end

    def expression_for(minutes)
      return "every day at noon #{Time.zone.tzinfo.name}" if whole_days?(minutes)

      "#{cron_for_tick(tick_minutes(minutes))} #{ELAPSED_ZONE}"
    end

    def tick_minutes(minutes)
      [ minutes, DAY_MINUTES ].min.downto(1).find { |step| (minutes % step).zero? && uniform_tick?(step) }
    end

    def uniform_tick?(step)
      return true if step <= 1
      return (60 % step).zero? if step < 60

      hours, remainder = step.divmod(60)
      remainder.zero? && (hours == 1 || (24 % hours).zero?)
    end

    def cron_for_tick(step)
      return "every minute" if step <= 1
      return "every #{step} minutes" if step < 60

      hours = step / 60
      return "every hour" if hours == 1

      "every #{hours} hours"
    end

    def calendar_days_between(earlier, later)
      (later.in_time_zone.to_date - earlier.in_time_zone.to_date).to_i
    end

    def schedule_slot(time, interval_seconds)
      Fugit.parse(schedule_for(interval_seconds)).previous_time(time + 1.second).to_t
    end
  end
end
