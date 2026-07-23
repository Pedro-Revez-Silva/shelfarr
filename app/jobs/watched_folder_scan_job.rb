# frozen_string_literal: true

# Recurring, self-rescheduling job that scans the configured watched-folder
# import path for pre-existing book files. Mirrors the scheduling pattern of
# DownloadMonitorJob / TelegramPollingJob: a single concurrency key prevents
# overlapping scans, and each run re-arms the next at the configured interval.
class WatchedFolderScanJob < ApplicationJob
  SCHEDULE_CACHE_KEY = "watched_folder_scan/next_run_at"
  # Progress/result of the most recent manual scan, for the review-queue UI.
  # Backed by the shared cache (solid_cache in production) and written only by
  # the worker running the scan, so the web process rendering the queue sees a
  # consistent state and never a stuck "running" flag from a crossed process.
  STATUS_CACHE_KEY = "watched_folder_scan/status"
  DEFAULT_INTERVAL_SECONDS = 300
  MIN_INTERVAL_SECONDS = 30
  MAX_INTERVAL_SECONDS = 86_400

  queue_as :default
  limits_concurrency key: "watched_folder_scan", duration: 1.hour, on_conflict: :discard

  class << self
    def scanning_enabled?
      SettingsService.get(:library_import_enabled, default: false) &&
        SettingsService.get(:library_import_path).to_s.strip.present?
    end

    # Snapshot of the latest manual scan for the queue UI: state ("running" /
    # "idle"), when it completed, and how many candidates/new detections it saw.
    # Empty until the first manual scan runs (or in an environment whose cache is
    # not shared across processes, e.g. development's memory store).
    def scan_status
      Rails.cache.read(STATUS_CACHE_KEY) || {}
    end

    def scanning_now?
      scan_status[:state] == "running"
    end

    def mark_running!
      write_status(state: "running", started_at: Time.current)
    end

    def mark_completed!(result)
      write_status(
        state: "idle",
        completed_at: Time.current,
        scanned: result&.scanned,
        detected: result&.detected,
        failed: result.nil?
      )
    end

    def broadcast_queue_refresh
      Turbo::StreamsChannel.broadcast_refresh_to(DetectedImport::INDEX_STREAM)
    rescue => e
      Rails.logger.warn "[WatchedFolderScanJob] Could not broadcast queue refresh (#{e.class})"
    end

    def ensure_running!
      return unless scanning_enabled?
      return if scan_job_pending?

      next_run_at = Rails.cache.read(SCHEDULE_CACHE_KEY).to_i
      return if next_run_at > Time.current.to_i

      reserve_schedule!
      Rails.logger.info "[WatchedFolderScanJob] Scheduling watched-folder scan chain"
      perform_later
    end

    def clear_schedule!
      Rails.cache.delete(SCHEDULE_CACHE_KEY)
    end

    def scan_job_pending?(excluding_active_job_id: nil)
      return false unless solid_queue_adapter?

      scope = SolidQueue::Job.where(class_name: name, finished_at: nil)
      scope = scope.where.not(active_job_id: excluding_active_job_id) if excluding_active_job_id.present?
      scope.exists?
    rescue ActiveRecord::StatementInvalid, NameError
      false
    end

    def interval_seconds
      SettingsService.get(:library_import_scan_interval, default: DEFAULT_INTERVAL_SECONDS)
        .to_i
        .clamp(MIN_INTERVAL_SECONDS, MAX_INTERVAL_SECONDS)
    end

    private

    def write_status(attrs)
      Rails.cache.write(STATUS_CACHE_KEY, attrs, expires_in: 1.day)
    rescue => e
      Rails.logger.warn "[WatchedFolderScanJob] Could not record scan status (#{e.class})"
    end

    def reserve_schedule!
      Rails.cache.write(
        SCHEDULE_CACHE_KEY,
        interval_seconds.seconds.from_now.to_i,
        expires_in: [ interval_seconds * 3, 300 ].max.seconds
      )
    end

    def solid_queue_adapter?
      ActiveJob::Base.queue_adapter.class.name == "ActiveJob::QueueAdapters::SolidQueueAdapter"
    end
  end

  # manual: true is passed by the "Scan now" button. Such a scan announces its
  # progress to the review queue (a spinner while it runs, its result when it
  # finishes) and refreshes the queue on completion so new detections appear
  # without a manual reload. The recurring background scan stays silent — it only
  # records its completion so "last scanned" stays fresh, and relies on the
  # per-record broadcasts to surface anything it finds.
  def perform(manual: false)
    unless self.class.scanning_enabled?
      self.class.clear_schedule!
      return
    end

    if manual
      self.class.mark_running!
      self.class.broadcast_queue_refresh
    end

    result = WatchedFolderScanService.scan!
    self.class.mark_completed!(result)
    self.class.broadcast_queue_refresh if manual
  rescue => e
    Rails.logger.error "[WatchedFolderScanJob] Scan failed (#{e.class}): #{e.message}"
    self.class.mark_completed!(nil)
    self.class.broadcast_queue_refresh if manual
  ensure
    schedule_next_run if self.class.scanning_enabled?
  end

  private

  def schedule_next_run
    return if self.class.scan_job_pending?(excluding_active_job_id: job_id)

    self.class.send(:reserve_schedule!)
    WatchedFolderScanJob.set(wait: self.class.interval_seconds.seconds).perform_later
  end
end
