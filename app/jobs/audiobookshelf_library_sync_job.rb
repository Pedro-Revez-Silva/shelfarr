# frozen_string_literal: true

# Recurring job that syncs library items from Audiobookshelf (or other library
# platforms) into Shelfarr's inventory cache used for duplicate detection.
class AudiobookshelfLibrarySyncJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1,
    key: "audiobookshelf-library-sync",
    duration: 10.minutes

  # Delay after a library-platform scan so remote indexers (BookOrbit, ABS,
  # Grimmory) have time to discover newly imported files before we refresh
  # Shelfarr's inventory cache used for duplicate detection.
  POST_SCAN_REFRESH_WAIT = 90.seconds
  POST_SCAN_REFRESH_CACHE_KEY = "library-platform-post-scan-refresh"

  class << self
    def discard_legacy_scheduled_chains!
      discarded = 0
      legacy_scheduled_jobs.find_each do |job|
        next unless legacy_periodic_arguments?(job.arguments)
        next unless job.status.in?([ :ready, :scheduled ])

        job.discard
        discarded += 1
      rescue SolidQueue::Execution::UndiscardableError, ActiveRecord::RecordNotFound
        next
      end
      discarded
    end

    private

    def legacy_scheduled_jobs
      SolidQueue::Job
        .where(class_name: name, finished_at: nil)
        .where('"solid_queue_jobs"."scheduled_at" > "solid_queue_jobs"."created_at"')
        .where.missing(:recurring_execution, :claimed_execution, :failed_execution)
    end

    def legacy_periodic_arguments?(payload)
      return false unless payload.is_a?(Hash)

      args = Array(payload["arguments"])
      return true if args.empty?

      first_arg = args.first
      return false unless first_arg.is_a?(Hash)

      first_arg["schedule_next"] != false && first_arg["scheduled"] != true
    end
  end

  def perform(scheduled: false)
    return unless LibraryPlatformClient.configured?
    return if scheduled && !sync_due?

    AudiobookshelfLibrarySyncService.new.sync!
  end

  # Coalesce bulk imports: only one delayed full-inventory sync is scheduled
  # per wait window, no matter how many files call this method.
  def self.schedule_post_scan_refresh!
    return unless LibraryPlatformClient.configured?

    claimed = Rails.cache.write(
      POST_SCAN_REFRESH_CACHE_KEY,
      true,
      expires_in: POST_SCAN_REFRESH_WAIT,
      unless_exist: true
    )
    return unless claimed

    set(wait: POST_SCAN_REFRESH_WAIT).perform_later
  end

  private

  def sync_due?
    last_sync = LibraryItem.maximum(:updated_at)
    return true if last_sync.nil?

    interval = SettingsService.get(:audiobookshelf_library_sync_interval, default: 3600).to_i
    interval = [ interval, 60 ].max
    interval_minutes = (interval / 1.minute.to_f).ceil

    last_sync.beginning_of_minute <= interval_minutes.minutes.ago.beginning_of_minute
  end
end
