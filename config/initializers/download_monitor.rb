# frozen_string_literal: true

# Start the download monitor job chain when the application boots
Rails.application.config.after_initialize do
  # Only start in server mode, not in console or rake tasks
  if defined?(Rails::Server)
    if DownloadMonitorJob.monitoring_required?
      Rails.logger.info "[Shelfarr] Starting DownloadMonitorJob chain"
      DownloadMonitorJob.ensure_running!
    else
      Rails.logger.info "[Shelfarr] No downloads require monitoring, DownloadMonitorJob not started"
    end
  end
rescue => e
  # Don't crash the app if there's an issue starting the monitor
  Rails.logger.error "[Shelfarr] Failed to start DownloadMonitorJob: #{e.message}"
end
