# frozen_string_literal: true

SolidQueue.on_scheduler_start do |scheduler|
  Rails.application.executor.wrap do
    IntervalRecurringTasks.start!(scheduler.recurring_schedule.configured_tasks)
  end
end
SolidQueue.on_scheduler_stop { IntervalRecurringTasks.stop! }
