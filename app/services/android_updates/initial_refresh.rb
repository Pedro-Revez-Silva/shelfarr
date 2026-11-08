# frozen_string_literal: true

module AndroidUpdates
  # At boot, a server that offers Android builds but has none cached yet (a
  # fresh install, a newly enabled channel) fetches them in the background
  # rather than waiting for the next scheduled refresh.
  module InitialRefresh
    module_function

    # Returns the channels it queued a refresh for.
    def call(configuration: Configuration.current, store: Store.new)
      if configuration.misconfigured?
        Rails.logger.warn "[AndroidUpdates] Android builds are not offered: #{configuration.error}"
        return []
      end

      missing = configuration.channels.reject { |channel| store.ready_release(channel) }
      if missing.any?
        Rails.logger.info "[AndroidUpdates] Fetching Android builds for #{missing.join(', ')} in the background"
        AndroidUpdateRefreshJob.perform_later
      end
      missing
    end
  end
end
