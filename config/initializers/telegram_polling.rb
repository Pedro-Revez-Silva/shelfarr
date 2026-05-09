# frozen_string_literal: true

Rails.application.config.after_initialize do
  if defined?(Rails::Server)
    TelegramPollingJob.ensure_running!
  end
rescue => e
  Rails.logger.error "[Shelfarr] Failed to start TelegramPollingJob: #{e.message}"
end
