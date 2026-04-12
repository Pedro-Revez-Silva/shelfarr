# frozen_string_literal: true

# Recurring job that monitors active downloads and triggers post-processing on completion
class DownloadMonitorJob < ApplicationJob
  NOT_FOUND_THRESHOLD = 3
  SCHEDULE_CACHE_KEY = "download_monitor/next_run_at"

  queue_as :default

  class << self
    def ensure_running!
      return unless DownloadClient.enabled.exists?

      interval = poll_interval_seconds
      next_run_at = Rails.cache.read(SCHEDULE_CACHE_KEY).to_i
      return if next_run_at > Time.current.to_i

      reserve_schedule!(interval)
      Rails.logger.info "[DownloadMonitorJob] Scheduling monitor chain"
      perform_later
    end

    def clear_schedule!
      Rails.cache.delete(SCHEDULE_CACHE_KEY)
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
      [interval * 3, 300].max.seconds
    end
  end

  def perform
    unless any_client_configured?
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
      handle_stale_queued_download(download)
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
    Rails.logger.info "[DownloadMonitorJob] Download #{download.id} completed"

    download.update!(
      status: :completed,
      progress: 100,
      download_path: info.download_path
    )
    track_request_event(download.request, "completed", download: download, message: "Download completed in client", details: { download_path: info.download_path })

    # Trigger post-processing
    PostProcessingJob.perform_later(download.id)
  end

  def handle_failed(download)
    Rails.logger.error "[DownloadMonitorJob] Download #{download.id} failed in client"

    track_request_event(download.request, "failed", download: download, message: "Download failed in client", level: :error)
    download.update!(status: :failed)
    download.request.mark_for_attention!("Download failed in client")
    NotificationService.request_attention(download.request)
  end

  def handle_missing(download)
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
      download.request.mark_for_attention!("Download not found in client '#{client_name}' (hash: #{download.external_id})")
      NotificationService.request_attention(download.request)
    else
      Rails.logger.warn "[DownloadMonitorJob] Download #{download.id} (hash: #{download.external_id}) not found in client '#{client_name}' (attempt #{new_count}/#{NOT_FOUND_THRESHOLD})"

      download.update!(not_found_count: new_count)
    end
  end

  def handle_stale_queued_download(download)
    return unless download.queued?

    timeout_minutes = SettingsService.get(:download_enqueue_timeout_minutes, default: 5).to_i
    return if timeout_minutes <= 0
    return if download.created_at > timeout_minutes.minutes.ago

    Rails.logger.error "[DownloadMonitorJob] Download #{download.id} stayed queued for more than #{timeout_minutes} minutes without reaching a download client"

    track_request_event(
      download.request,
      "dispatch_stalled",
      download: download,
      message: "Download stayed queued for more than #{timeout_minutes} minutes without an external client ID",
      level: :warn
    )
    download.update!(status: :failed)
    download.request.mark_for_attention!(
      "Download stayed queued in Shelfarr for more than #{timeout_minutes} minutes and was never sent to the download client. Retry the request and check the job queue/logs."
    )
    NotificationService.request_attention(download.request)
  end

  def schedule_next_run
    interval = self.class.send(:poll_interval_seconds)
    Rails.cache.write(
      self.class::SCHEDULE_CACHE_KEY,
      interval.seconds.from_now.to_i,
      expires_in: self.class.send(:schedule_ttl, interval)
    )
    DownloadMonitorJob.set(wait: interval.seconds).perform_later
  end

  def any_client_configured?
    DownloadClient.enabled.exists?
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
