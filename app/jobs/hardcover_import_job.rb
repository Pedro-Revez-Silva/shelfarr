# frozen_string_literal: true

# Creates requests for queued Hardcover subscription items in bounded
# batches. One import runs at a time across the instance so two batches can
# never race to request the same book.
class HardcoverImportJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "hardcover-import", duration: 15.minutes

  CONTINUE_DELAY = 5.seconds

  def perform
    result = Hardcover::ItemImporter.call
    self.class.set(wait: CONTINUE_DELAY).perform_later if result.processed.positive? && result.remaining.positive?
  end
end
