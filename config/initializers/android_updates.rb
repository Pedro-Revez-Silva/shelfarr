# frozen_string_literal: true

# Web requests never fetch Android builds; a server with nothing cached yet
# queues one background refresh at boot (see AndroidUpdates::InitialRefresh).
Rails.application.config.after_initialize do
  AndroidUpdates::InitialRefresh.call if defined?(Rails::Server)
rescue StandardError => e
  Rails.logger.error "[AndroidUpdates] Could not schedule the Android build refresh: #{e.class.name}"
end
