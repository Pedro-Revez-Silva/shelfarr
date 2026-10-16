# frozen_string_literal: true

class UpdateCheckJob < ApplicationJob
  queue_as :default

  def perform
    result = UpdateCheckerService.check(force: true)

    if result.update_available?
      Rails.logger.info "[UpdateCheckJob] Update available: #{result.current_version} -> #{result.latest_version}"
      Rails.logger.info "[UpdateCheckJob] Latest commit: #{result.latest_message}"
    else
      Rails.logger.debug "[UpdateCheckJob] No updates available (current: #{result.current_version})"
    end
  end
end
