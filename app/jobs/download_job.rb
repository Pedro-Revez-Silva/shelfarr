# frozen_string_literal: true

class DownloadJob < ApplicationJob
  queue_as :default

  def perform(download_id)
    download = Download.find_by(id: download_id)
    return unless download
    return unless download.queued?

    Rails.logger.info "[DownloadJob] Starting download ##{download.id} for request ##{download.request.id}"

    search_result = download.request.search_results.selected.first

    unless search_result
      Rails.logger.error "[DownloadJob] No selected search result for download ##{download.id}"
      download.update!(status: :failed)
      download.request.mark_for_attention!("No search result selected for download")
      return
    end

    begin
      # Handle Anna's Archive downloads differently
      if search_result.from_anna_archive?
        handle_anna_archive_download(download, search_result)
      else
        handle_standard_download(download, search_result)
      end
    rescue DownloadClientSelector::NoClientAvailableError => e
      Rails.logger.error "[DownloadJob] No download client available: #{e.message}"
      download.update!(status: :failed)
      download.request.mark_for_attention!(e.message)
    rescue DownloadClients::Base::AuthenticationError => e
      Rails.logger.error "[DownloadJob] Download client authentication failed: #{e.message}"
      download.update!(status: :failed)
      download.request.mark_for_attention!("Download client authentication failed. Please check credentials.")
    rescue DownloadClients::Base::ConnectionError => e
      Rails.logger.error "[DownloadJob] Download client connection error: #{e.message}"
      download.update!(status: :failed)
      download.request.mark_for_attention!("Failed to connect to download client: #{e.message}")
    rescue DownloadClients::Base::Error => e
      Rails.logger.error "[DownloadJob] Download client error for download ##{download.id}: #{e.message}"
      download.update!(status: :failed)
      download.request.mark_for_attention!("Download client error: #{e.message}")
    rescue AnnaArchiveClient::Error => e
      Rails.logger.error "[DownloadJob] Anna's Archive error for download ##{download.id}: #{e.message}"
      download.update!(status: :failed)
      download.request.mark_for_attention!("Anna's Archive error: #{e.message}")
    end
  end

  private

  def handle_anna_archive_download(download, search_result)
    # Fetch actual download URL from Anna's Archive API
    md5 = search_result.guid
    Rails.logger.info "[DownloadJob] Fetching download URL from Anna's Archive for MD5: #{md5}"

    download_url = AnnaArchiveClient.get_download_url(md5)
    Rails.logger.info "[DownloadJob] Got download URL: #{download_url.truncate(100)}"

    # Check if it's a torrent/magnet link or direct download
    if download_url.start_with?("magnet:") || download_url.end_with?(".torrent")
      # Send to torrent client
      send_to_torrent_client(download, search_result, download_url)
    else
      # Direct download - we need to handle this differently
      # For now, try sending to torrent client anyway (some clients accept direct links)
      # TODO: Implement direct HTTP download if needed
      Rails.logger.warn "[DownloadJob] Anna's Archive returned direct link, attempting via torrent client"
      send_to_torrent_client(download, search_result, download_url)
    end
  end

  def send_to_torrent_client(download, search_result, download_url)
    # Select torrent client
    client_record = DownloadClientSelector.for_torrent
    client = client_record.adapter

    Rails.logger.info "[DownloadJob] Using client '#{client_record.name}' for download ##{download.id}"

    result = client.add_torrent(download_url)

    if result
      download.update!(
        status: :downloading,
        download_client: client_record,
        external_id: extract_external_id_from_url(download_url, result),
        download_type: "torrent"
      )
      Rails.logger.info "[DownloadJob] Successfully added torrent for download ##{download.id}"
    else
      download.update!(status: :failed)
      download.request.mark_for_attention!("Failed to add to #{client_record.name}")
      Rails.logger.error "[DownloadJob] Failed to add download ##{download.id}"
    end
  end

  def handle_standard_download(download, search_result)
    unless search_result.downloadable?
      Rails.logger.error "[DownloadJob] Search result has no download link for download ##{download.id}"
      download.update!(status: :failed)
      download.request.mark_for_attention!("Selected result has no download link")
      return
    end

    # Select best available client based on download type and priority
    client_record = DownloadClientSelector.for_download(search_result)
    client = client_record.adapter

    Rails.logger.info "[DownloadJob] Using client '#{client_record.name}' for download ##{download.id}"

    result = client.add_torrent(search_result.download_link)

    if result
      download.update!(
        status: :downloading,
        download_client: client_record,
        external_id: extract_external_id(search_result, result),
        download_type: search_result.usenet? ? "usenet" : "torrent"
      )
      Rails.logger.info "[DownloadJob] Successfully added #{download.download_type} for download ##{download.id}"
    else
      download.update!(status: :failed)
      download.request.mark_for_attention!("Failed to add to #{client_record.name}")
      Rails.logger.error "[DownloadJob] Failed to add download ##{download.id}"
    end
  end

  def extract_external_id(search_result, result)
    if search_result.download_link&.start_with?("magnet:")
      # Extract hash from magnet link
      search_result.download_link.match(/btih:([a-fA-F0-9]+)/i)&.[](1)
    elsif result.is_a?(Hash) && result["nzo_ids"]
      # SABnzbd returns nzo_id in response
      result["nzo_ids"].first
    end
  end

  def extract_external_id_from_url(url, result)
    if url.start_with?("magnet:")
      # Extract hash from magnet link
      url.match(/btih:([a-fA-F0-9]+)/i)&.[](1)
    elsif result.is_a?(Hash) && result["hash"]
      result["hash"]
    end
  end
end
