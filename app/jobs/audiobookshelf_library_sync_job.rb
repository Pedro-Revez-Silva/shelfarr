# frozen_string_literal: true

class AudiobookshelfLibrarySyncJob < ApplicationJob
  module ConcurrencyLease
    KEYS = %w[
      AudiobookshelfLibrarySyncJob/audiobookshelf-library-sync
      HardcoverSyncSchedulerJob/hardcover-sync-scheduler
      DownloadMonitorJob/download_monitor
    ].freeze

    module ExcludeClaimed
      def expired
        relation = super
        keys = AudiobookshelfLibrarySyncJob::ConcurrencyLease.protected_keys
        keys.empty? ? relation : relation.where.not(key: keys)
      end
    end

    class << self
      def install!
        return if @installed

        SolidQueue::Semaphore.singleton_class.prepend(ExcludeClaimed)
        @installed = true
      end

      # Solid Queue stamps the semaphore expiry when it dispatches a job to
      # ready, and claiming that job does not refresh the lease. Keep the
      # semaphore until the ready or claimed execution is gone.
      def protected_keys
        SolidQueue::Job
          .where(concurrency_key: KEYS, finished_at: nil)
          .left_outer_joins(:ready_execution, :claimed_execution)
          .where(
            "solid_queue_ready_executions.id IS NOT NULL OR solid_queue_claimed_executions.id IS NOT NULL"
          )
          .distinct
          .pluck(:concurrency_key)
      end
    end
  end
  ConcurrencyLease.install!

  queue_as :default
  limits_concurrency to: 1,
    key: "audiobookshelf-library-sync",
    duration: 10.minutes

  # Delay after a library-platform scan so remote indexers (BookOrbit, ABS,
  # Grimmory) have time to discover newly imported files before we refresh
  # Shelfarr's inventory cache used for duplicate detection.
  POST_SCAN_REFRESH_WAIT = 90.seconds
  POST_SCAN_REFRESH_CACHE_KEY = "library-platform-post-scan-refresh"
  LAST_SCHEDULED_ATTEMPT_AT_CACHE_KEY = "library-platform-last-scheduled-sync-at"

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

      first_arg["schedule_next"] != false &&
        first_arg["scheduled"] != true &&
        first_arg["post_scan"] != true
    end

    def post_scan_refresh_pending?
      return false unless solid_queue_adapter?

      SolidQueue::Job
        .where(class_name: name, finished_at: nil)
        .where.missing(:recurring_execution, :claimed_execution, :failed_execution)
        .any? { |job| ready_or_scheduled_post_scan?(job) }
    rescue ActiveRecord::ActiveRecordError, NameError => error
      RemoteResult::Failed.new(error)
    end

    def ready_or_scheduled_post_scan?(job)
      status = job.status
      status = status.to_sym if status.respond_to?(:to_sym)
      return false unless %i[ready scheduled].include?(status)

      arguments = job.arguments.is_a?(Hash) ? Array(job.arguments["arguments"]) : []
      keywords = arguments.find { |argument| argument.is_a?(Hash) } || {}
      keywords["post_scan"] == true
    end

    def solid_queue_adapter?
      ActiveJob::Base.queue_adapter.class.name == "ActiveJob::QueueAdapters::SolidQueueAdapter"
    end
  end

  # Extra one-shot metadata accepts both the pre-migration schedule_next flag
  # and the explicit post_scan marker without letting either establish a new
  # recurring chain.
  def perform(scheduled: false, **_one_shot_metadata)
    release_unconfigured_integration_connections!
    return unless LibraryPlatformClient.configured?
    return if scheduled && !sync_due?

    record_scheduled_attempt! if scheduled
    AudiobookshelfLibrarySyncService.new.sync!
  end

  # Coalesce bulk imports: only one delayed full-inventory sync is scheduled
  # per wait window, no matter how many files call this method. A refresh that
  # is already waiting keeps its deadline when a later import arrives after the
  # cache reservation expires.
  def self.schedule_post_scan_refresh!
    return unless LibraryPlatformClient.configured?
    return if post_scan_refresh_pending? == true

    claimed = Rails.cache.write(
      POST_SCAN_REFRESH_CACHE_KEY,
      true,
      expires_in: POST_SCAN_REFRESH_WAIT,
      unless_exist: true
    )
    return unless claimed

    SingleChain.enqueue(
      self,
      wait: POST_SCAN_REFRESH_WAIT,
      scope: { post_scan: true },
      post_scan: true
    )
  end

  private

  def sync_due?
    interval = SettingsService.get(:audiobookshelf_library_sync_interval, default: 3600).to_i
    return false if interval <= 0

    last_attempt = Rails.cache.read(LAST_SCHEDULED_ATTEMPT_AT_CACHE_KEY)
    return true unless last_attempt.respond_to?(:beginning_of_minute)

    interval = [ interval, 60 ].max
    interval_minutes = (interval / 1.minute.to_f).ceil

    last_attempt.beginning_of_minute <= interval_minutes.minutes.ago.beginning_of_minute
  end

  def record_scheduled_attempt!
    Rails.cache.write(LAST_SCHEDULED_ATTEMPT_AT_CACHE_KEY, Time.current)
  end

  def release_unconfigured_integration_connections!
    LibraryPlatformClient.release_unconfigured_connections!
    IndexerClient.release_unconfigured_connections!
    FlaresolverrClient.release_unconfigured_connection!
    GutenbergClient.release_unconfigured_connection!
    LibrivoxClient.release_unconfigured_connection!
  end
end
