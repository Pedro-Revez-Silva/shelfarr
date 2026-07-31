# frozen_string_literal: true

# Recurring, self-rescheduling job that scans the configured watched-folder
# import path for pre-existing book files. Mirrors the scheduling pattern of
# DownloadMonitorJob / TelegramPollingJob: a single concurrency key prevents
# overlapping scans, and each run re-arms the next at the configured interval.
class WatchedFolderScanJob < ApplicationJob
  SCHEDULE_CACHE_KEY = "watched_folder_scan/next_run_at"
  # Progress/result of the latest scan, for the review-queue UI. Backed by the
  # shared cache (solid_cache in production) and written only by the worker
  # running the scan, so the web process never sees a crossed-process state.
  STATUS_CACHE_KEY = "watched_folder_scan/status"
  DEFAULT_INTERVAL_SECONDS = 300
  MIN_INTERVAL_SECONDS = 30
  MAX_INTERVAL_SECONDS = 86_400
  # How long the cache may claim a scan is running. Matches the concurrency lease
  # below: past it the worker cannot still hold the key, so a stuck "running" is
  # the residue of a killed worker and must not keep disabling "Scan now".
  RUNNING_STATUS_TTL = 1.hour

  queue_as :default
  limits_concurrency key: "watched_folder_scan", duration: 1.hour, on_conflict: :discard

  class << self
    def scanning_enabled?
      SettingsService.get(:library_import_enabled, default: false) &&
        SettingsService.get(:library_import_path).to_s.strip.present?
    end

    # Snapshot for the queue UI: state ("running" / "idle"), when it completed,
    # and how many candidates/new detections it saw. Empty until the first scan
    # runs, or where the cache is not shared across processes (development).
    def scan_status
      status = Rails.cache.read(STATUS_CACHE_KEY) || {}
      return status unless stale_running?(status)

      # Report an abandoned run as failed, not live, so the queue offers "Scan
      # now" again instead of spinning until the cache expires. Not written back:
      # the next scan overwrites it, and writing here would race the key's owner.
      status.merge(state: "idle", completed_at: status[:started_at], failed: true)
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

    # Arm the next link of the chain unless one is already pending. The running
    # job passes its own active_job_id so it does not count itself and leave the
    # chain unarmed.
    def schedule_next!(excluding_active_job_id: nil)
      return if scan_job_pending?(excluding_active_job_id: excluding_active_job_id)

      reserve_schedule!
      set(wait: interval_seconds.seconds).perform_later
    end

    def clear_schedule!
      Rails.cache.delete(SCHEDULE_CACHE_KEY)
    end

    def scan_job_pending?(excluding_active_job_id: nil)
      return false unless solid_queue_adapter?

      # Solid Queue keeps failed rows forever with finished_at still NULL, so
      # counting them as pending would convince ensure_running! the chain is
      # alive and stop it enqueuing a replacement. Excluded as DownloadMonitorJob
      # does.
      scope = SolidQueue::Job
        .where(class_name: name, finished_at: nil)
        .where.missing(:failed_execution)
      scope = scope.where.not(active_job_id: excluding_active_job_id) if excluding_active_job_id.present?
      scope.exists?
    rescue ActiveRecord::ActiveRecordError, NameError
      false
    end

    def interval_seconds
      SettingsService.get(:library_import_scan_interval, default: DEFAULT_INTERVAL_SECONDS)
        .to_i
        .clamp(MIN_INTERVAL_SECONDS, MAX_INTERVAL_SECONDS)
    end

    private

    def stale_running?(status)
      status[:state] == "running" &&
        (status[:started_at].blank? || status[:started_at] < RUNNING_STATUS_TTL.ago)
    end

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

  # manual: true comes from the "Scan now" button, and pushes progress to the
  # review queue (a spinner, then the result) so detections appear without a
  # reload. The background scan stays silent — per-record broadcasts surface what
  # it finds — but records the same status, because that status is what tells the
  # queue a scan is in flight. Recording it only for manual scans let the screen
  # offer "Scan now" during a background scan, whose concurrency key then
  # discarded the manual job after the admin was told it had started.
  def perform(manual: false)
    unless self.class.scanning_enabled?
      self.class.clear_schedule!
      return
    end

    self.class.mark_running!
    self.class.broadcast_queue_refresh if manual

    # Only the scan is rescued, so the status and refresh are written on exactly
    # one path; mark_completed!(nil) already reports the run as failed.
    result = begin
      WatchedFolderScanService.scan!
    rescue => e
      Rails.logger.error "[WatchedFolderScanJob] Scan failed (#{e.class}): #{e.message}"
      nil
    end

    self.class.mark_completed!(result)
    self.class.broadcast_queue_refresh if manual
  ensure
    schedule_next_run if self.class.scanning_enabled?
  end

  private

  def schedule_next_run
    self.class.schedule_next!(excluding_active_job_id: job_id)
  end
end
