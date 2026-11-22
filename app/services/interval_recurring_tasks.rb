# frozen_string_literal: true

class IntervalRecurringTasks
  POLL_SECONDS = 60
  JOBS = {
    "health_check" => "HealthCheckJob",
    "audiobookshelf_library_sync" => "AudiobookshelfLibrarySyncJob"
  }.freeze

  class << self
    def start!(configured_tasks, interval: POLL_SECONDS)
      stop!
      keys = JOBS.keys - configured_tasks.map(&:key)
      return if keys.empty?

      @timer = Concurrent::TimerTask.new(execution_interval: interval) { poll!(keys) }
      poll!(keys)
      @timer.execute
    end

    def stop!
      @timer&.shutdown
      @timer = nil
    end

    def poll!(keys = JOBS.keys)
      Rails.application.executor.wrap do
        ActiveRecord::Base.uncached do
          keys.each do |key|
            enqueue_if_due(key)
          rescue ActiveRecord::ActiveRecordError => error
            Rails.logger.warn "[Shelfarr] Interval task #{key} will be checked again: #{error.message}"
          end
        end
      end
    end

    private

    def enqueue_if_due(key)
      job_class = JOBS.fetch(key).constantize
      return unless job_class.scheduled_due?

      SolidQueue::Job.transaction do
        SolidQueue::Job.uncached do
          next if interval_job_pending?(key)

          slot = Time.current.beginning_of_minute
          next if SolidQueue::RecurringExecution.exists?(task_key: key, run_at: slot)
          next unless job_class.scheduled_due?

          SolidQueue::RecurringTask.from_configuration(key, class: job_class.name, args: [ { scheduled: true } ])
            .enqueue(at: slot)
        end
      end
    end

    def interval_job_pending?(key)
      SolidQueue::Job.joins(:recurring_execution)
        .where(solid_queue_recurring_executions: { task_key: key }, finished_at: nil)
        .where.missing(:failed_execution).exists?
    end
  end
end
