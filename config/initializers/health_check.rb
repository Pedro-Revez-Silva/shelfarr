# frozen_string_literal: true

# Initialize health check records and start the health check job chain when the application boots
Rails.application.config.after_initialize do
  # Only start in server mode, not in console or rake tasks
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

    Rails.logger.info "[Shelfarr] Starting HealthCheckJob chain"
    HealthCheckJob.perform_later
  end
rescue => e
  # Don't crash the app if there's an issue starting the health check
  Rails.logger.error "[Shelfarr] Failed to start HealthCheckJob: #{e.message}"
end
