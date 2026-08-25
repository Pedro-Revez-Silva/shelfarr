# frozen_string_literal: true

# Initialize health check records when the application boots
Rails.application.config.after_initialize do
  # Only run in server mode, not in console or rake tasks
  if defined?(Rails::Server)
    # Ensure SystemHealth records exist for all services so the dashboard
    # never shows a blank "Not checked" state
    begin
      SystemHealth::SERVICES.each do |service|
        SystemHealth.find_or_create_by!(service: service) do |health|
          health.status = :not_configured
          health.message = "Waiting for first health check"
        end
      end
    rescue => e
      Rails.logger.warn "[Shelfarr] Could not seed SystemHealth records: #{e.message}"
    end

    # Clean up leftover pending HealthCheckJob rows from the self-rescheduling chain bug
    # This allows existing installs to heal on next deploy
    begin
      deleted_count = SolidQueue::Job.where(
        class_name: "HealthCheckJob",
        finished_at: nil
      ).delete_all

      if deleted_count > 0
        Rails.logger.info "[Shelfarr] Cleaned up #{deleted_count} pending HealthCheckJob(s) from previous install"
      end
    rescue => e
      Rails.logger.warn "[Shelfarr] Could not clean up pending HealthCheckJob rows: #{e.message}"
    end
  end
rescue => e
  Rails.logger.error "[Shelfarr] Failed to initialize health check: #{e.message}"
end
