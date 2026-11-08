# frozen_string_literal: true

# Keeps the server's copy of the Shelfarr Android builds current. Scheduled
# from config/recurring.yml and once at boot while nothing is cached yet.
class AndroidUpdateRefreshJob < ApplicationJob
  queue_as :default

  def perform(force: false)
    outcome = AndroidUpdates::Refresher.new.call(force: force)
    Rails.logger.debug { "[AndroidUpdates] Refresh #{outcome.status}: #{outcome.channels.to_json}" }
    outcome.status
  end
end
