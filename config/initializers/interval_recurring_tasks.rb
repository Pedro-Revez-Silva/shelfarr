# frozen_string_literal: true

SolidQueue.on_scheduler_start do
  Rails.application.executor.wrap { IntervalRecurringTasks.reconcile!(replace_static: true) }
end
SolidQueue::Scheduler.after_boot do
  IntervalRecurringTasks.scheduler_started!(dynamic_tasks_enabled: dynamic_tasks_enabled?)
end
SolidQueue.on_scheduler_stop { IntervalRecurringTasks.scheduler_stopped! }
