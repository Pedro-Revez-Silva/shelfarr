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

    begin
      discarded_count = HealthCheckJob.discard_legacy_scheduled_chains!

      if discarded_count.positive?
        Rails.logger.info(
          "[Shelfarr] Discarded #{discarded_count} legacy scheduled HealthCheckJob chain entries"
        )
      end
    rescue => e
      Rails.logger.warn "[Shelfarr] Could not clean up legacy HealthCheckJob chains: #{e.message}"
    end
  end
rescue => e
  Rails.logger.error "[Shelfarr] Failed to initialize health check: #{e.message}"
end
