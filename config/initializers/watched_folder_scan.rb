# frozen_string_literal: true

# Start the watched-folder scan job chain when the application boots, if the
# feature is enabled and a path is configured.
Rails.application.config.after_initialize do
  # Only start in server mode, not in console or rake tasks.
  if defined?(Rails::Server)
    if WatchedFolderScanJob.scanning_enabled?
      Rails.logger.info "[Shelfarr] Starting WatchedFolderScanJob chain"
      WatchedFolderScanJob.ensure_running!
    else
      Rails.logger.info "[Shelfarr] Watched-folder import disabled, WatchedFolderScanJob not started"
    end
  end
rescue => e
  # Don't crash the app if there's an issue starting the scanner.
  Rails.logger.error "[Shelfarr] Failed to start WatchedFolderScanJob: #{e.message}"
end
