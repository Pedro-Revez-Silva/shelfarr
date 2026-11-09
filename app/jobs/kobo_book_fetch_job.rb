# frozen_string_literal: true

# Prepares one private DRM-free copy of a Kobo account purchase. The job
# carries only row ids and a random request id, never credentials or URLs.
class KoboBookFetchJob < ApplicationJob
  queue_as :default

  def perform(file_id, request_id)
    row = KoboAccountBookFile.find_by(id: file_id)
    return unless row && row.status == "fetching" && row.request_id == request_id

    logger = ActiveRecord::Base.logger
    if logger&.respond_to?(:silence)
      logger.silence(Logger::INFO) { Kobo::BookCache.new(row).call }
    else
      Kobo::BookCache.new(row).call
    end
  end
end
