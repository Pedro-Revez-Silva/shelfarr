# frozen_string_literal: true

class AudiobookshelfLibrarySyncJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1,
    key: "audiobookshelf-library-sync",
    duration: 10.minutes

  # Delay after a library-platform scan so remote indexers (BookOrbit, ABS,
  # Grimmory) have time to discover newly imported files before we refresh
  # Shelfarr's inventory cache used for duplicate detection.
  POST_SCAN_REFRESH_WAIT = 90.seconds

  # schedule_next: false for one-shot post-grab refreshes that must not reset
  # the periodic sync cadence.
  def perform(schedule_next: true)
    return unless LibraryPlatformClient.configured?

    AudiobookshelfLibrarySyncService.new.sync!
  ensure
    schedule_next_run if schedule_next
  end

  def self.schedule_post_scan_refresh!
    return unless LibraryPlatformClient.configured?

    set(wait: POST_SCAN_REFRESH_WAIT).perform_later(schedule_next: false)
  end

  private

  def schedule_next_run
    return unless LibraryPlatformClient.configured?

    interval = SettingsService.get(:audiobookshelf_library_sync_interval, default: 3600).to_i
    return if interval <= 0

    AudiobookshelfLibrarySyncJob.set(wait: interval.seconds).perform_later
  end
end
