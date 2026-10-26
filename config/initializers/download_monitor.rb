# frozen_string_literal: true

Rails.application.config.after_initialize do
  # Workers are not Rails::Server. Drop argument-less successors before they
  # can be claimed and skip the interval gate.
  discarded = DownloadMonitorJob.discard_legacy_pending_monitors!
  if discarded.is_a?(Integer) && discarded.positive?
    Rails.logger.info "[Shelfarr] Cleaned up #{discarded} legacy DownloadMonitorJob(s)"
  end

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
