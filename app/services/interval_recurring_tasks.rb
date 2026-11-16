# frozen_string_literal: true

require "fugit"

# health_check and audiobookshelf_library_sync follow Settings intervals.
# A static every-minute tick still inserts a Solid Queue job on every skip,
# and a running scheduler only notices dynamic tasks that are deleted and
# created again, so changing an interval replaces the row.
# Solid Queue only plans the next future tick, so startup of bin/jobs enqueues
# one scheduled run. The job's due-check performs overdue work and skips the rest.
class IntervalRecurringTasks
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

  class << self
    def sync_all!(catch_up: false)
      TASKS.each_key { |key| sync_task!(key) }
      enqueue_catch_up! if catch_up
    end

    def sync_setting!(setting_key)
      setting_key = setting_key.to_sym
      key = TASKS.each_key.find { |task_key| TASKS.fetch(task_key)[:setting] == setting_key }
      sync_task!(key) if key
    end

    # Exact sub-day intervals keep a matching cron. Anything else uses the
    # coarsest uniform tick that divides it, and the due-check keeps the
    # requested spacing instead of rounding the interval up.
    # Multi-day month grids restart on the 1st, so 7 days is weekly and
    # other multi-day values tick daily. The due-check keeps that spacing.
    def schedule_for(interval_seconds)
      minutes = [ (interval_seconds.to_f / 60).ceil, 1 ].max
      expression = expression_for(minutes)
      parsed = Fugit.parse(expression)
      unless parsed.is_a?(Fugit::Cron)
        raise ArgumentError, "unsupported recurring schedule #{expression.inspect}"
      end

      expression
    end

    # A late start records the next minute, so the following slot looks early
    # against that timestamp. Comparing slots keeps the configured spacing.
    # Local midnights are not a fixed number of seconds apart across DST.
    def due?(last_at, interval_seconds, now: Time.current)
      return true unless last_at.respond_to?(:beginning_of_minute)

      seconds = [ interval_seconds.to_i, 60 ].max
      last_minute = last_at.beginning_of_minute
      now_minute = now.beginning_of_minute
      return false if now_minute <= last_minute

      previous_slot = schedule_slot(last_minute, seconds)
      current_slot = schedule_slot(now_minute, seconds)
      minutes = (seconds / 60.0).ceil
      if minutes >= 24 * 60
        calendar_days_between(previous_slot, current_slot) >= calendar_day_count(minutes)
      else
        current_slot >= previous_slot + minutes.minutes
      end
    end

    private

    def sync_task!(key)
      attempts = 0
      begin
        attempts += 1
        write_task!(key)
      rescue ActiveRecord::RecordNotUnique
        retry if attempts < 3
        raise
      end
    end

    def write_task!(key)
      config = TASKS.fetch(key)
      schedule = desired_schedule(config)

      SolidQueue::RecurringTask.transaction do
        existing = SolidQueue::RecurringTask.find_by(key: key)
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

    def expression_for(minutes)
      return day_cron(calendar_day_count(minutes)) if minutes >= 24 * 60

      cron_for_tick(tick_minutes(minutes))
    end

    # Largest repeating cron step that divides the interval. 75 minutes
    # ticks every 15; 31 minutes has no coarser step than one minute.
    def tick_minutes(minutes)
      minutes.downto(1).find { |step| (minutes % step).zero? && uniform_tick?(step) }
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

    def calendar_day_count(minutes)
      (minutes / (24.0 * 60)).ceil
    end

    def calendar_days_between(earlier, later)
      (later.in_time_zone.to_date - earlier.in_time_zone.to_date).to_i
    end

    def day_cron(days)
      return "every Sunday" if days == 7

      "every day"
    end

    # previous_time is exclusive, so step forward to keep an exact slot.
    def schedule_slot(time, interval_seconds)
      Fugit.parse(schedule_for(interval_seconds)).previous_time(time + 1.second).to_t
    end

    def enqueue_catch_up!
      TASKS.each_value do |config|
        next if desired_schedule(config).nil?

        config[:job_class].constantize.perform_later(scheduled: true)
      end
    end
  end
end
