# frozen_string_literal: true

SolidQueue.on_scheduler_start { IntervalRecurringTasks.scheduler_started! }
SolidQueue.on_scheduler_stop { IntervalRecurringTasks.scheduler_stopped! }
