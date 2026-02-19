# frozen_string_literal: true

# Start the periodic Audiobookshelf library sync job when the server boots
Rails.application.config.after_initialize do
  if defined?(Rails::Server) && AudiobookshelfClient.configured?
    Rails.logger.info "[Shelfarr] Starting AudiobookshelfLibrarySyncJob"
    AudiobookshelfLibrarySyncJob.perform_later
  end
rescue => e
  Rails.logger.error "[Shelfarr] Failed to start AudiobookshelfLibrarySyncJob: #{e.message}"
end
