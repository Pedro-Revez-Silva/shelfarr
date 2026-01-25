# frozen_string_literal: true

# Recurring job that monitors active downloads and triggers post-processing on completion
class DownloadMonitorJob < ApplicationJob
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
    return unless download.external_id.present?
    return unless download.download_client&.enabled?

    client = download.download_client.adapter
    info = client.torrent_info(download.external_id)

    return handle_missing(download) unless info

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

    # Trigger post-processing
    PostProcessingJob.perform_later(download.id)
  end

  def handle_failed(download)
    Rails.logger.error "[DownloadMonitorJob] Download #{download.id} failed in client"

    download.update!(status: :failed)
    download.request.mark_for_attention!("Download failed in client")
  end

  def handle_missing(download)
    client_name = download.download_client&.name || "unknown"
    Rails.logger.error "[DownloadMonitorJob] Download #{download.id} (hash: #{download.external_id}) not found in client '#{client_name}'"

    download.update!(status: :failed)
    download.request.mark_for_attention!("Download not found in client '#{client_name}' (hash: #{download.external_id})")
  end

  def schedule_next_run
    interval = SettingsService.get(:download_check_interval, default: 60)
    DownloadMonitorJob.set(wait: interval.seconds).perform_later
  end

  def any_client_configured?
    DownloadClient.enabled.exists?
  end
end
