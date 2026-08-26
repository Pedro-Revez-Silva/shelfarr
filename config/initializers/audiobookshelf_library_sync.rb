# frozen_string_literal: true

# Clean up duplicate self-rescheduling AudiobookshelfLibrarySyncJob chains that
# accumulated before the job was migrated to recurring.yml.
#
# Before the fix in issue #488, AudiobookshelfLibrarySyncJob.perform_later calls
# (from startup, settings changes, etc.) used the default schedule_next: true
# behavior and each established a self-rescheduling chain that persisted in
# Solid Queue, similar to the HealthCheckJob leak addressed in an earlier PR.
#
# This cleanup preserves:
# - schedule_next: false post-scan refreshes (intentional one-shots)
# - scheduled: true recurring jobs (the new cadence from recurring.yml)
# - currently running or claimed work
# - failed historical records
Rails.application.config.after_initialize do
  next unless Rails.env.production?
  next unless defined?(SolidQueue::Job)

  begin
    SolidQueue::Record.establish_connection(:queue)
    if SolidQueue::Job.connection.table_exists?("solid_queue_jobs")
      discarded_count = AudiobookshelfLibrarySyncJob.discard_legacy_scheduled_chains!
      if discarded_count > 0
        Rails.logger.info "[Shelfarr] Cleaned up #{discarded_count} legacy AudiobookshelfLibrarySyncJob chain(s)"
      end
    end
  rescue => e
    Rails.logger.error "[Shelfarr] Failed to clean up legacy AudiobookshelfLibrarySyncJob chains: #{e.message}"
  end
end
