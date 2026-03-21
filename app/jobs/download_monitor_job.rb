# frozen_string_literal: true

# Recurring job that monitors active downloads and triggers post-processing on completion
class DownloadMonitorJob < ApplicationJob
  NOT_FOUND_THRESHOLD = 3

  queue_as :default

  def perform
    return unless any_client_configured?

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
  end

  def schedule_next_run
    interval = SettingsService.get(:download_check_interval, default: 60)
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
