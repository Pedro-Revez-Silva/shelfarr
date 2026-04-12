# frozen_string_literal: true

class DownloadJob < ApplicationJob
  queue_as :default

  def perform(download_id)
    download = Download.find_by(id: download_id)
    unless download
      Rails.logger.warn "[DownloadJob] Download ##{download_id} not found when job started"
      return
    end

    return unless download.queued?

    Rails.logger.info "[DownloadJob] Starting download ##{download.id} for request ##{download.request.id}"
    track_request_event(
      download.request,
      "dispatch_started",
      download: download,
      message: "Started dispatching download to a client",
      details: { request_status: download.request.status }
    )

    search_result = download.request.search_results.selected.first

    unless search_result
      Rails.logger.error "[DownloadJob] No selected search result for download ##{download.id}"
      track_request_event(download.request, "dispatch_failed", download: download, message: "No search result selected for download", level: :error)
      download.update!(status: :failed)
      download.request.mark_for_attention!("No search result selected for download")
      return
    end

    begin
      # Handle Anna's Archive downloads differently
      if search_result.from_anna_archive?
        handle_anna_archive_download(download, search_result)
      elsif search_result.from_zlibrary?
        handle_zlibrary_download(download, search_result)
      else
        handle_standard_download(download, search_result)
      end
    rescue DownloadClientSelector::NoClientAvailableError => e
      Rails.logger.error "[DownloadJob] No download client available: #{e.message}"
      track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
      download.update!(status: :failed)
      download.request.mark_for_attention!(e.message)
    rescue DownloadClients::Base::AuthenticationError => e
      Rails.logger.error "[DownloadJob] Download client authentication failed: #{e.message}"
      track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
      download.update!(status: :failed)
      download.request.mark_for_attention!("Download client authentication failed. Please check credentials.")
    rescue DownloadClients::Base::ConnectionError => e
      Rails.logger.error "[DownloadJob] Download client connection error: #{e.message}"
      track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
      download.update!(status: :failed)
      download.request.mark_for_attention!("Failed to connect to download client: #{e.message}")
    rescue DownloadClients::Base::Error => e
      Rails.logger.error "[DownloadJob] Download client error for download ##{download.id}: #{e.message}"
      track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
      download.update!(status: :failed)
      download.request.mark_for_attention!("Download client error: #{e.message}")
    rescue AnnaArchiveClient::Error => e
      Rails.logger.error "[DownloadJob] Anna's Archive error for download ##{download.id}: #{e.message}"
      track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
      download.update!(status: :failed)
      download.request.mark_for_attention!("Anna's Archive error: #{e.message}")
    rescue ZLibraryClient::Error => e
      Rails.logger.error "[DownloadJob] Z-Library error for download ##{download.id}: #{e.message}"
      track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
      download.update!(status: :failed)
      download.request.mark_for_attention!("Z-Library error: #{e.message}")
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
      # Direct HTTP download - download file directly
      Rails.logger.info "[DownloadJob] Anna's Archive returned direct link, downloading via HTTP"
      handle_direct_http_download(download, search_result, download_url)
    end
  end

  def handle_zlibrary_download(download, search_result)
    book_id, file_hash = search_result.guid.to_s.split(":", 2)
    raise ZLibraryClient::Error, "Selected Z-Library result is missing download metadata" if book_id.blank? || file_hash.blank?

    Rails.logger.info "[DownloadJob] Fetching Z-Library download URL for book #{book_id}"
    download_url = ZLibraryClient.get_download_url(id: book_id, hash: file_hash)

    handle_direct_http_download(download, search_result, download_url)
  end

  def handle_direct_http_download(download, search_result, download_url)
    book = download.request.book

    # Build destination path similar to how PostProcessingJob does it
    base_path = SettingsService.get(:ebook_output_path, default: "/ebooks")
    destination_dir = PathTemplateService.build_destination(book, base_path: base_path)

    # Infer filename from URL or search result
    filename = infer_filename_from_url(download_url, search_result)
    destination_path = File.join(destination_dir, filename)

    Rails.logger.info "[DownloadJob] Downloading directly to: #{destination_path}"

    # Ensure directory exists
    FileUtils.mkdir_p(destination_dir)

    # Download the file
    download_file_via_http(search_result, download_url, destination_path)
    verify_downloaded_ebook!(destination_path)

    # Update download record as completed
    download.update!(
      status: :completed,
      download_path: destination_path,
      download_type: "direct"
    )

    # Update book with file path
    book.update!(file_path: destination_dir)

    # Complete the request
    download.request.complete!

    # Trigger library scan if configured
    trigger_library_scan(book) if AudiobookshelfClient.configured?

    # Send notification
    NotificationService.request_completed(download.request)
    track_request_event(download.request, "completed", download: download, message: "Direct download completed")

    Rails.logger.info "[DownloadJob] Direct download completed: #{destination_path}"
  rescue => e
    Rails.logger.error "[DownloadJob] Direct download failed: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    track_request_event(download.request, "failed", download: download, message: e.message, level: :error)
    download.update!(status: :failed)
    download.request.mark_for_attention!("Direct download failed: #{e.message}")
  end

  def infer_filename_from_url(url, search_result)
    # Try to get filename from URL path
    uri = URI.parse(url)
    filename_from_url = File.basename(uri.path)

    # URL-decode the filename (converts %20 to space, %3A to colon, etc.)
    filename_from_url = URI.decode_www_form_component(filename_from_url) if filename_from_url.present?

    # If URL has a valid filename with extension, use it
    if filename_from_url.present? && filename_from_url.include?(".")
      return sanitize_filename(filename_from_url)
    end

    # Fall back to constructing from search result
    book = search_result.request.book
    title = book.title.presence || "Unknown"
    author = book.author.presence || "Unknown"

    # Infer extension from search result or URL
    extension = infer_extension(url, search_result)

    sanitize_filename("#{author} - #{title}.#{extension}")
  end

  def infer_extension(url, search_result)
    # Check URL for extension hints
    return "epub" if url.include?("epub")
    return "pdf" if url.include?("pdf")
    return "mobi" if url.include?("mobi")

    # Check search result title
    title = search_result.title.to_s.downcase
    return "epub" if title.include?("epub")
    return "pdf" if title.include?("pdf")
    return "mobi" if title.include?("mobi")

    # Default to epub
    "epub"
  end

  def sanitize_filename(name)
    result = name
      .gsub(/[<>:"\/\\|?*]/, "_")
      .gsub(/[\x00-\x1f]/, "")
      .strip
      .gsub(/\s+/, " ")

    # Truncate while preserving file extension
    max_length = 200
    if result.length > max_length
      ext = File.extname(result)
      base = File.basename(result, ext)
      base = base.truncate(max_length - ext.length, omission: "")
      result = "#{base}#{ext}"
    end

    result
  end

  def download_file_via_http(search_result, url, destination)
    uri = validate_direct_download_url!(url, search_result)

    Rails.logger.info "[DownloadJob] Starting HTTP download..."

    response = direct_download_connection(uri).get(uri.request_uri)
    raise "Direct download failed with status #{response.status}" unless response.success?

    File.open(destination, "wb") do |dest|
      dest.write(response.body)
    end

    file_size = File.size(destination)
    Rails.logger.info "[DownloadJob] Downloaded #{(file_size / 1024.0 / 1024.0).round(2)} MB"
  rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
    raise "Direct download request failed: #{e.message}"
  end

  def validate_direct_download_url!(url, search_result = nil)
    uri = URI.parse(url)
    raise "Invalid direct download URL" unless %w[http https].include?(uri.scheme) && uri.host.present?

    if search_result&.from_zlibrary? && !zlibrary_download_host_allowed?(uri.host)
      raise "Invalid direct download URL host"
    end

    uri
  rescue URI::InvalidURIError => e
    raise "Invalid direct download URL: #{e.message}"
  end

  def direct_download_connection(uri)
    Faraday.new(url: direct_download_base_url(uri)) do |f|
      f.adapter Faraday.default_adapter
      f.headers["User-Agent"] = "Shelfarr/1.0"
      f.options.timeout = 300
      f.options.open_timeout = 30
    end
  end

  def direct_download_base_url(uri)
    default_port = (uri.scheme == "https" ? 443 : 80)
    port_suffix = uri.port == default_port ? "" : ":#{uri.port}"
    "#{uri.scheme}://#{uri.host}#{port_suffix}"
  end

  def zlibrary_download_host_allowed?(host)
    configured_host = URI.parse(SettingsService.get(:zlibrary_url).to_s).host
    return false if configured_host.blank?

    host == configured_host || host.end_with?(".#{configured_host}")
  rescue URI::InvalidURIError
    false
  end

  def verify_downloaded_ebook!(path)
    raise "Downloaded file does not exist" unless File.exist?(path)

    file_size = File.size(path)
    raise "Downloaded file is empty" if file_size.zero?

    head = File.binread(path, 256)
    lowered = head.downcase
    if lowered.include?("<html") || lowered.include?("<!doctype")
      FileUtils.rm_f(path)
      raise "Downloaded file is an HTML page, not an ebook"
    end
  rescue Errno::ENOENT => e
    raise "Downloaded file is missing: #{e.message}"
  end

  def trigger_library_scan(book)
    lib_id = if book.audiobook?
      SettingsService.get(:audiobookshelf_audiobook_library_id)
    else
      SettingsService.get(:audiobookshelf_ebook_library_id)
    end

    return unless lib_id.present?

    AudiobookshelfClient.scan_library(lib_id)
    Rails.logger.info "[DownloadJob] Triggered Audiobookshelf library scan for #{book.book_type}"
  rescue AudiobookshelfClient::Error => e
    Rails.logger.warn "[DownloadJob] Failed to trigger scan: #{e.message}"
  end

  def send_to_torrent_client(download, search_result, download_url)
    # Select torrent client
    client_record = DownloadClientSelector.for_torrent
    client = client_record.adapter

    Rails.logger.info "[DownloadJob] Using client '#{client_record.name}' for download ##{download.id}"

    # add_torrent now returns the hash directly (or nil on failure)
    torrent_hash = client.add_torrent(download_url)

    if torrent_hash
      # Defensive check: warn if another download already has this external_id
      check_for_duplicate_external_id(torrent_hash, download.id)

      download.update!(
        status: :downloading,
        download_client: client_record,
        external_id: torrent_hash,
        download_type: "torrent"
      )
      track_request_event(
        download.request,
        "dispatched",
        download: download,
        message: "Sent torrent download to #{client_record.name}",
        details: {
          client_name: client_record.name,
          download_type: "torrent",
          external_id: torrent_hash
        }
      )
      Rails.logger.info "[DownloadJob] Successfully added torrent for download ##{download.id}, hash: #{torrent_hash}"
    else
      track_request_event(
        download.request,
        "dispatch_failed",
        download: download,
        message: "Client did not return a torrent hash",
        level: :error,
        details: { client_name: client_record.name }
      )
      download.update!(status: :failed)
      download.request.mark_for_attention!("Failed to add to #{client_record.name}")
      Rails.logger.error "[DownloadJob] Failed to add download ##{download.id}"
    end
  end

  def handle_standard_download(download, search_result)
    unless search_result.downloadable?
      Rails.logger.error "[DownloadJob] Search result has no download link for download ##{download.id}"
      track_request_event(download.request, "dispatch_failed", download: download, message: "Selected result has no download link", level: :error)
      download.update!(status: :failed)
      download.request.mark_for_attention!("Selected result has no download link")
      return
    end

    # Select best available client based on download type and priority
    client_record = DownloadClientSelector.for_download(search_result)
    client = client_record.adapter
    is_usenet = search_result.usenet?

    Rails.logger.info "[DownloadJob] Using client '#{client_record.name}' for download ##{download.id}"

    download_link = search_result.download_link
    Rails.logger.info "[DownloadJob] Download link type: #{is_usenet ? 'usenet' : 'torrent'}, length: #{download_link.to_s.length} chars"
    Rails.logger.debug "[DownloadJob] Full download URL: #{download_link}"

    if is_usenet
      # SABnzbd returns a hash with nzo_ids
      result = client.add_torrent(download_link)
      external_id = result.is_a?(Hash) ? result["nzo_ids"]&.first : nil
      success = external_id.present?
    else
      # qBittorrent now returns the torrent hash directly
      external_id = client.add_torrent(download_link)
      success = external_id.present?
    end

    if success
      # Defensive check: warn if another download already has this external_id
      # This should not happen with the race condition fix, but log it if it does
      check_for_duplicate_external_id(external_id, download.id)

      download.update!(
        status: :downloading,
        download_client: client_record,
        external_id: external_id,
        download_type: is_usenet ? "usenet" : "torrent"
      )
      track_request_event(
        download.request,
        "dispatched",
        download: download,
        message: "Sent #{download.download_type} download to #{client_record.name}",
        details: {
          client_name: client_record.name,
          download_type: download.download_type,
          external_id: external_id
        }
      )
      Rails.logger.info "[DownloadJob] Successfully added #{download.download_type} for download ##{download.id}, external_id: #{external_id}"
    else
      track_request_event(
        download.request,
        "dispatch_failed",
        download: download,
        message: "Client did not return an external ID",
        level: :error,
        details: {
          client_name: client_record.name,
          download_type: is_usenet ? "usenet" : "torrent"
        }
      )
      download.update!(status: :failed)
      download.request.mark_for_attention!("Failed to add to #{client_record.name}")
      Rails.logger.error "[DownloadJob] Failed to add download ##{download.id}"
    end
  end

  def check_for_duplicate_external_id(external_id, current_download_id)
    return if external_id.blank?

    existing = Download.where(external_id: external_id)
                       .where.not(id: current_download_id)
                       .where.not(status: :failed)
                       .first

    if existing
      Rails.logger.error "[DownloadJob] DUPLICATE EXTERNAL_ID DETECTED! " \
                         "Download ##{current_download_id} is being assigned external_id #{external_id}, " \
                         "but Download ##{existing.id} (request ##{existing.request_id}) already has this ID. " \
                         "This indicates a potential race condition that should be investigated."
    end
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
