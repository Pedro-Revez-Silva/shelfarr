# frozen_string_literal: true

require "fugit"

# health_check and audiobookshelf_library_sync follow Settings intervals.
# A static every-minute tick still inserts a Solid Queue job on every skip,
# and a running scheduler only notices dynamic tasks that are deleted and
# created again, so changing an interval replaces the row.
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
    def sync_all!
      TASKS.each_key { |key| sync_task!(key) }
    end

    def sync_setting!(setting_key)
      setting_key = setting_key.to_sym
      key = TASKS.each_key.find { |task_key| TASKS.fetch(task_key)[:setting] == setting_key }
      sync_task!(key) if key
    end

    # Sub-day crons use the finest grid whose gap is at least the interval.
    # Multi-day month grids restart on the 1st, so 7 days is weekly and
    # other multi-day values tick daily. The due-check keeps that elapsed gap.
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
    def due?(last_at, interval_seconds, now: Time.current)
      return true unless last_at.respond_to?(:beginning_of_minute)

      seconds = [ interval_seconds.to_i, 60 ].max
      last_minute = last_at.beginning_of_minute
      now_minute = now.beginning_of_minute
      return false if now_minute <= last_minute

      interval_minutes = (seconds / 60.0).ceil
      schedule_slot(now_minute, seconds) >= schedule_slot(last_minute, seconds) + interval_minutes.minutes
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
      if minutes < 60
        minute_cron(minutes)
      elsif minutes < 24 * 60
        hour_cron((minutes / 60.0).ceil)
      else
        day_cron((minutes / (24.0 * 60)).ceil)
      end
    end

    def minute_cron(step)
      return "every minute" if step <= 1

      slots = stepped_slots(step, 60)
      return "every hour" if slots == [ 0 ]
      return "every #{step} minutes" if slots == (0...60).step(step).to_a

      "#{slots.join(",")} * * * *"
    end

    def hour_cron(step)
      slots = stepped_slots(step, 24)
      return "every day" if slots == [ 0 ]
      return "every hour" if step == 1
      return "every #{step} hours" if (24 % step).zero? && slots == (0...24).step(step).to_a

      "0 #{slots.join(",")} * * *"
    end

    def day_cron(days)
      return "every Sunday" if days == 7

      "every day"
    end

    # previous_time is exclusive, so step forward to keep an exact slot.
    def schedule_slot(time, interval_seconds)
      Fugit.parse(schedule_for(interval_seconds)).previous_time(time + 1.second).to_t
    end

    # Drop the last slot when the wrap back to zero would be shorter than step.
    def stepped_slots(step, modulus)
      slots = (0...modulus).step(step).to_a
      slots.pop if slots.length > 1 && (modulus % step) != 0
      slots.empty? ? [ 0 ] : slots
    end
  end
end
