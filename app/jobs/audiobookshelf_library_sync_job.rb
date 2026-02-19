# frozen_string_literal: true

class AudiobookshelfLibrarySyncJob < ApplicationJob
  queue_as :default

  def perform
    return unless AudiobookshelfClient.configured?

    AudiobookshelfLibrarySyncService.new.sync!
  ensure
    schedule_next_run
  end

  private

  def schedule_next_run
    interval = SettingsService.get(:audiobookshelf_library_sync_interval, default: 3600).to_i
    return if interval <= 0

    AudiobookshelfLibrarySyncJob.set(wait: interval.seconds).perform_later
  end
end
