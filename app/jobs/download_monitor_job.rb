# frozen_string_literal: true

# Recurring job that monitors active downloads and triggers post-processing on completion
class DownloadMonitorJob < ApplicationJob
  CONCURRENCY_KEY = "download_monitor"
  NOT_FOUND_THRESHOLD = 3
  SCHEDULE_CACHE_KEY = "download_monitor/next_run_at"
  DIRECT_DOWNLOAD_STALE_TIMEOUT = 30.minutes

  queue_as :default
  limits_concurrency key: CONCURRENCY_KEY, duration: 30.minutes

  class << self
    def ensure_running!
      return unless monitoring_required?
      return if monitor_job_pending?

      interval = poll_interval_seconds
      unless solid_queue_adapter?
        next_run_at = Rails.cache.read(SCHEDULE_CACHE_KEY).to_i
        return if next_run_at > Time.current.to_i
      end

      reserve_schedule!(interval)
      Rails.logger.info "[DownloadMonitorJob] Scheduling monitor chain"
      perform_later
    end

    def monitoring_required?
      return true if DownloadClient.enabled.exists?
      return true if Download.active.where(download_type: [ "direct", "dispatching" ]).exists?

      Download.active
        .where(download_type: [ nil, "" ])
        .includes(:search_result)
        .any? { |download| download.search_result&.direct_download? }
    end

    def clear_schedule!
      Rails.cache.delete(SCHEDULE_CACHE_KEY)
    end

    def monitor_job_pending?(excluding_active_job_id: nil)
      return false unless solid_queue_adapter?

      scope = SolidQueue::Job
        .where(class_name: name, finished_at: nil)
        .where.not(concurrency_key: nil)
        .where.missing(:failed_execution, :claimed_execution)
      scope = scope.where.not(active_job_id: excluding_active_job_id) if excluding_active_job_id.present?
      scope.exists?
    rescue ActiveRecord::ActiveRecordError, NameError
      false
    end

    private

    def reserve_schedule!(interval)
      Rails.cache.write(
        SCHEDULE_CACHE_KEY,
        interval.seconds.from_now.to_i,
        expires_in: schedule_ttl(interval)
      )
    end

    def poll_interval_seconds
      SettingsService.get(:download_check_interval, default: 60).to_i.clamp(1, 86_400)
    end

    def schedule_ttl(interval)
      [ interval * 3, 300 ].max.seconds
    end

    def solid_queue_adapter?
      ActiveJob::Base.queue_adapter.class.name == "ActiveJob::QueueAdapters::SolidQueueAdapter"
    end
  end

  def perform
    unless self.class.monitoring_required?
      self.class.clear_schedule!
      return
    end

    monitor_active_downloads
    schedule_next_run
  end

  private

  def monitor_active_downloads
    Download.active.find_each do |download|
      check_download_status(download)
    rescue => e
      Rails.logger.error "[DownloadMonitorJob] Error checking download #{download.id}: #{e.message}"
    end
  end

  def check_download_status(download)
    unless download.external_id.present?
      if download.download_type == "direct"
        handle_stale_direct_download(download)
      else
        handle_stale_queued_download(download)
      end
      return
    end

    return unless download.download_client&.enabled?

    client = download.download_client.adapter
    info = client.torrent_info(download.external_id)

    return handle_missing(download) unless info

    download.update!(not_found_count: 0) if download.not_found_count > 0
    update_progress(download, info)

    if info.completed?
      handle_completed(download, info)
    elsif info.failed?
      handle_failed(download)
    end
  end

  def update_progress(download, info)
    download.update!(progress: info.progress) if download.progress != info.progress
  end

  def handle_completed(download, info)
    claimed = Download
      .where(id: download.id, status: Download.statuses[:downloading])
      .update_all(
        status: Download.statuses[:completed],
        progress: 100,
        download_path: info.download_path,
        updated_at: Time.current
      )
    return unless claimed == 1

    download.reload
    Rails.logger.info "[DownloadMonitorJob] Download #{download.id} completed"
    track_request_event(download.request, "completed", download: download, message: "Download completed in client", details: { download_path: info.download_path })

    # Trigger post-processing
    PostProcessingJob.perform_later(download.id)
  end

  def handle_failed(download)
    download.request.with_lock do
      download.reload
      next unless current_monitored_download?(download)

      Rails.logger.error "[DownloadMonitorJob] Download #{download.id} failed in client"
      track_request_event(download.request, "failed", download: download, message: "Download failed in client", level: :error)
      download.update!(status: :failed)
      download.request.handle_download_failure!(download, reason: "Download failed in client")
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def handle_missing(download)
    download.request.with_lock do
      download.reload
      next unless current_monitored_download?(download)

      client_name = download.download_client&.name || "unknown"
      new_count = download.not_found_count + 1

      if new_count >= NOT_FOUND_THRESHOLD
        Rails.logger.error "[DownloadMonitorJob] Download #{download.id} (hash: #{download.external_id}) not found in client '#{client_name}' after #{new_count} consecutive checks"

        track_request_event(
          download.request,
          "failed",
          download: download,
          message: "Download not found in client after #{new_count} checks",
          level: :error,
          details: { client_name: client_name }
        )
        download.update!(status: :failed, not_found_count: new_count)
        download.request.handle_download_failure!(download, reason: "Download not found in client '#{client_name}' (hash: #{download.external_id})")
      else
        Rails.logger.warn "[DownloadMonitorJob] Download #{download.id} (hash: #{download.external_id}) not found in client '#{client_name}' (attempt #{new_count}/#{NOT_FOUND_THRESHOLD})"

        download.update!(not_found_count: new_count)
      end
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def handle_stale_queued_download(download)
    return unless download.queued? || download.downloading?

    timeout_minutes = SettingsService.get(:download_enqueue_timeout_minutes, default: 5).to_i
    return if timeout_minutes <= 0
    cutoff = timeout_minutes.minutes.ago
    download.request.with_lock do
      stale_scope = Download.where(id: download.id, external_id: [ nil, "" ])
      stale_scope = if download.queued?
        stale_scope.where(status: Download.statuses[:queued]).where("created_at <= ?", cutoff)
      else
        stale_scope
          .where(
            status: Download.statuses[:downloading],
            download_type: [ nil, "", "dispatching", "torrent", "usenet" ]
          )
          .where("updated_at <= ?", cutoff)
      end
      claimed = stale_scope.update_all(status: Download.statuses[:failed], updated_at: Time.current)
      next unless claimed == 1

      download.reload
      Rails.logger.error "[DownloadMonitorJob] Download #{download.id} stayed queued for more than #{timeout_minutes} minutes without reaching a download client"
      track_request_event(
        download.request,
        "dispatch_stalled",
        download: download,
        message: "Download stayed queued for more than #{timeout_minutes} minutes without an external client ID",
        level: :warn
      )
      download.request.mark_for_attention!(
        "Download stayed queued in Shelfarr for more than #{timeout_minutes} minutes and was never sent to the download client. Retry the request and check the job queue/logs."
      )
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def handle_stale_direct_download(download)
    return unless download.downloading?
    cutoff = DIRECT_DOWNLOAD_STALE_TIMEOUT.ago
    stalled = false

    download.request.with_lock do
      claimed = Download
        .where(
          id: download.id,
          status: Download.statuses[:downloading],
          download_type: "direct",
          external_id: [ nil, "" ]
        )
        .where("updated_at <= ?", cutoff)
        .update_all(status: Download.statuses[:failed], updated_at: Time.current)
      next unless claimed == 1

      download.reload
      Rails.logger.error "[DownloadMonitorJob] Direct download #{download.id} stopped reporting progress"
      track_request_event(
        download.request,
        "dispatch_stalled",
        download: download,
        message: "Direct download stopped reporting progress",
        level: :warn
      )
      stalled = true
    end
    return unless stalled
    return if DirectDownloadFileService.reconcile!(download.reload)

    download.request.mark_for_attention!(
      "Direct download stopped reporting progress. Retry the request and check the job queue/logs."
    )
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def schedule_next_run
    return if self.class.monitor_job_pending?(excluding_active_job_id: job_id)

    interval = self.class.send(:poll_interval_seconds)
    Rails.cache.write(
      self.class::SCHEDULE_CACHE_KEY,
      interval.seconds.from_now.to_i,
      expires_in: self.class.send(:schedule_ttl, interval)
    )
    DownloadMonitorJob.set(wait: interval.seconds).perform_later
  end

  def current_monitored_download?(download)
    return false unless download.downloading? && download.external_id.present?
    return true if download.search_result_id.blank?

    download.request.search_results.selected.where(id: download.search_result_id).exists?
  end

  def track_request_event(request, event_type, download: nil, message: nil, level: :info, details: {})
    RequestEvent.record!(
      request: request,
      download: download,
      event_type: event_type,
      source: self.class.name,
      message: message,
      level: level,
      details: details
    )
  end
end
