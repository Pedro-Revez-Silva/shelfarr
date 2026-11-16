# frozen_string_literal: true

# bin/jobs loads the environment before the scheduler starts, so the dynamic
# rows exist in time for the first tick. db:prepare boots before the queue
# tables exist; that pass has nothing to register yet.
Rails.application.config.after_initialize do
  next if Rails.env.test?

  begin
    ready = SolidQueue::RecurringTask.connection.table_exists?("solid_queue_recurring_tasks")
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid => error
    Rails.logger.warn "[Shelfarr] Interval recurring tasks were not synced: #{error.message}"
    next
  end

  IntervalRecurringTasks.sync_all! if ready
end
