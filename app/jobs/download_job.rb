# frozen_string_literal: true

require "net/http"
require "uri"
require "tempfile"
require "timeout"
require "pathname"

class DownloadJob < ApplicationJob
  # Wraps network-level failures during a direct HTTP download so failure
  # handling can classify them as transient without message matching.
  class DirectDownloadError < StandardError; end
  class BookAcquisitionConflictError < StandardError; end

  queue_as :default

  MAX_DIRECT_DOWNLOAD_BYTES = 512.megabytes
  MAX_DIRECT_AUDIOBOOK_DOWNLOAD_BYTES = 2.gigabytes
  MAX_DIRECT_DOWNLOAD_REDIRECTS = 5
  MAX_DIRECT_ARCHIVE_ENTRIES = 10_000
  DIRECT_DOWNLOAD_HEARTBEAT_INTERVAL = 30.seconds
  DIRECT_EBOOK_EXTENSIONS = %w[epub pdf mobi azw3].freeze
  DIRECT_AUDIOBOOK_ARCHIVE_EXTENSIONS = %w[zip].freeze
  DIRECT_AUDIOBOOK_FILE_EXTENSIONS = %w[m4b mp3 m4a aac flac ogg opus].freeze
  DIRECT_AUDIOBOOK_EXTENSIONS = (DIRECT_AUDIOBOOK_ARCHIVE_EXTENSIONS + DIRECT_AUDIOBOOK_FILE_EXTENSIONS).freeze
  # Extensions that are also ordinary words ("Live at the Opus") and need
  # format-style context (".opus", "[opus]", "(opus)") in a title to count.
  AMBIGUOUS_AUDIOBOOK_EXTENSIONS = %w[opus].freeze

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

    search_result = download.search_result || download.request.search_results.selected.first

    unless search_result
      Rails.logger.error "[DownloadJob] No selected search result for download ##{download.id}"
      track_request_event(download.request, "dispatch_failed", download: download, message: "No search result selected for download", level: :error)
      download.update!(status: :failed)
      download.request.mark_for_attention!("No search result selected for download")
      return
    end
    download.update!(search_result: search_result) unless download.search_result_id
    return unless claim_dispatch!(download, search_result)

    begin
      # Handle Anna's Archive downloads differently
      if search_result.from_anna_archive?
        handle_anna_archive_download(download, search_result)
      elsif search_result.from_zlibrary?
        handle_zlibrary_download(download, search_result)
      elsif search_result.from_gutenberg?
        handle_gutenberg_download(download, search_result)
      elsif search_result.from_librivox?
        handle_librivox_download(download, search_result)
      elsif search_result.from_custom_provider?
        handle_custom_provider_download(download, search_result)
      else
        handle_standard_download(download, search_result)
      end
    rescue DownloadClientSelector::NoClientAvailableError => e
      with_current_dispatch(download) do
        Rails.logger.error "[DownloadJob] No download client available: #{e.message}"
        track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
        download.update!(status: :failed)
        download.request.mark_for_attention!(e.message)
      end
    rescue DownloadClients::Base::AuthenticationError => e
      with_current_dispatch(download) do
        Rails.logger.error "[DownloadJob] Download client authentication failed: #{e.message}"
        track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
        download.update!(status: :failed)
        download.request.mark_for_attention!("Download client authentication failed. Please check credentials.")
      end
    rescue DownloadClients::Base::ConnectionError => e
      with_current_dispatch(download) do
        Rails.logger.error "[DownloadJob] Download client connection error: #{e.message}"
        track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
        download.update!(status: :failed)
        download.request.mark_for_attention!("Failed to connect to download client: #{e.message}")
      end
    rescue DownloadClients::Base::Error => e
      with_current_dispatch(download) do
        Rails.logger.error "[DownloadJob] Download client error for download ##{download.id}: #{e.message}"
        track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
        download.update!(status: :failed)
        download.request.handle_download_failure!(download, reason: "Download client error: #{e.message}")
      end
    rescue AnnaArchiveClient::Error => e
      with_current_dispatch(download) do
        Rails.logger.error "[DownloadJob] Anna's Archive error for download ##{download.id}: #{e.message}"
        track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
        download.update!(status: :failed)
        handle_download_source_failure(download, e, "Anna's Archive error: #{e.message}")
      end
    rescue ZLibraryClient::Error => e
      with_current_dispatch(download) do
        Rails.logger.error "[DownloadJob] Z-Library error for download ##{download.id}: #{e.message}"
        track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
        download.update!(status: :failed)
        handle_download_source_failure(download, e, "Z-Library error: #{e.message}")
      end
    rescue LibrivoxClient::Error => e
      with_current_dispatch(download) do
        Rails.logger.error "[DownloadJob] LibriVox error for download ##{download.id}: #{e.message}"
        track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
        download.update!(status: :failed)
        handle_download_source_failure(download, e, "LibriVox error: #{e.message}")
      end
    rescue GutenbergClient::Error => e
      with_current_dispatch(download) do
        Rails.logger.error "[DownloadJob] Project Gutenberg error for download ##{download.id}: #{e.message}"
        track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
        download.update!(status: :failed)
        handle_download_source_failure(download, e, "Project Gutenberg error: #{e.message}")
      end
    rescue CustomAcquisitionProviderClient::Error => e
      with_current_dispatch(download) do
        Rails.logger.error "[DownloadJob] Custom provider error for download ##{download.id}: #{e.message}"
        track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
        download.update!(status: :failed)
        handle_download_source_failure(download, e, "Custom provider error: #{e.message}")
      end
    end
  end

  private

  def with_current_dispatch(download)
    download.request.with_lock do
      download.reload
      next unless download.queued? || download.downloading?

      yield
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def handle_download_source_failure(download, error, message)
    if transient_download_source_error?(error)
      download.request.mark_for_attention!(message)
    else
      download.request.handle_download_failure!(download, reason: message)
    end
  end

  def handle_direct_download_failure(download, error, message: nil)
    message ||= "Direct download failed: #{error.message}"
    if error.is_a?(BookAcquisitionConflictError) ||
        error.is_a?(DirectDownloadFileService::ConflictError) ||
        transient_direct_download_error?(error)
      download.request.mark_for_attention!(message)
    else
      download.request.handle_download_failure!(download, reason: message)
    end
  end

  def transient_direct_download_error?(error)
    case error
    when DirectDownloadError,
         SocketError, IOError, EOFError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError
      true
    else
      false
    end
  end

  def transient_download_source_error?(error)
    case error
    when AnnaArchiveClient::ConnectionError,
         AnnaArchiveClient::AuthenticationError,
         AnnaArchiveClient::NotConfiguredError,
         AnnaArchiveClient::ConfigurationError,
         AnnaArchiveClient::BotProtectionError,
         AnnaArchiveClient::RetryableError,
         ZLibraryClient::ConnectionError,
         ZLibraryClient::AuthenticationError,
         ZLibraryClient::NotConfiguredError,
         ZLibraryClient::RateLimitError,
         ZLibraryClient::ConfigurationError,
         LibrivoxClient::ConnectionError,
         LibrivoxClient::NotConfiguredError,
         LibrivoxClient::ConfigurationError,
         GutenbergClient::ConnectionError,
         GutenbergClient::NotConfiguredError,
         GutenbergClient::ConfigurationError,
         CustomAcquisitionProviderClient::ConnectionError,
         CustomAcquisitionProviderClient::NotConfiguredError,
         CustomAcquisitionProviderClient::ResponseError
      true
    else
      false
    end
  end

  def handle_anna_archive_download(download, search_result)
    # Fetch actual download URL from Anna's Archive API
    md5 = search_result.guid
    Rails.logger.info "[DownloadJob] Fetching download URL from Anna's Archive for MD5: #{md5}"

    download_url = AnnaArchiveClient.get_download_url(md5)
    Rails.logger.info "[DownloadJob] Got download URL: #{UrlRedactor.redact(download_url).truncate(100)}"

    # Check if it's a torrent/magnet link or direct download
    if torrent_download_url?(download_url)
      # Send to torrent client
      send_to_torrent_client(download, search_result, download_url)
    else
      # Direct HTTP download - download file directly
      Rails.logger.info "[DownloadJob] Anna's Archive returned direct link, downloading via HTTP"
      if download.request.book.audiobook?
        begin
          handle_direct_audiobook_download(download, search_result, download_url, source_name: "Anna's Archive")
        rescue => e
          fail_direct_dispatch!(download, e, message: "Anna's Archive download failed: #{e.message}")
        end
      else
        handle_direct_http_download(download, search_result, download_url)
      end
    end
  end

  def handle_zlibrary_download(download, search_result)
    book_id, file_hash = search_result.guid.to_s.split(":", 2)
    raise ZLibraryClient::Error, "Selected Z-Library result is missing download metadata" if book_id.blank? || file_hash.blank?

    Rails.logger.info "[DownloadJob] Fetching Z-Library download URL for book #{book_id}"
    download_url = ZLibraryClient.get_download_url(id: book_id, hash: file_hash)

    handle_direct_http_download(download, search_result, download_url)
  end

  def handle_gutenberg_download(download, search_result)
    raise GutenbergClient::Error, "Selected Project Gutenberg result is missing a download URL" if search_result.download_url.blank?

    handle_direct_http_download(download, search_result, search_result.download_url)
  end

  def handle_librivox_download(download, search_result)
    raise LibrivoxClient::Error, "Selected LibriVox result is missing a download URL" if search_result.download_url.blank?

    handle_direct_audiobook_archive_download(download, search_result, search_result.download_url, source_name: "LibriVox")
  rescue LibrivoxClient::Error
    raise
  rescue => e
    fail_direct_dispatch!(download, e, message: "LibriVox download failed: #{e.message}")
  end

  def handle_custom_provider_download(download, search_result)
    provider = search_result.acquisition_provider
    raise CustomAcquisitionProviderClient::NotConfiguredError, "Selected custom provider result is missing its provider" unless provider&.enabled?

    Rails.logger.info "[DownloadJob] Acquiring custom provider result from #{provider.name}"
    acquisition = provider.client.acquire(search_result)

    case acquisition.download_type
    when "direct"
      if download.request.book.audiobook?
        handle_direct_audiobook_download(download, search_result, acquisition.direct_url, source_name: provider.name)
      else
        handle_direct_http_download(download, search_result, acquisition.direct_url)
      end
    when "torrent"
      torrent_url = acquisition.magnet_url.presence || acquisition.direct_url
      send_to_torrent_client(download, search_result, validate_dispatch_url!(torrent_url, search_result))
    when "usenet"
      nzb_url = acquisition.nzb_url.presence || acquisition.direct_url
      send_to_usenet_client(download, search_result, validate_dispatch_url!(nzb_url, search_result))
    else
      raise CustomAcquisitionProviderClient::UnusableArtifactError, "Unsupported custom provider artifact type: #{acquisition.download_type}"
    end
  rescue CustomAcquisitionProviderClient::Error, DownloadClientSelector::NoClientAvailableError, DownloadClients::Base::Error
    raise
  rescue => e
    fail_direct_dispatch!(download, e, message: "Custom provider download failed: #{e.message}")
  end

  def handle_direct_audiobook_download(download, search_result, download_url, source_name:)
    extension = infer_audiobook_extension(download_url, search_result)

    if DIRECT_AUDIOBOOK_ARCHIVE_EXTENSIONS.include?(extension)
      handle_direct_audiobook_archive_download(download, search_result, download_url, source_name: source_name)
    elsif DIRECT_AUDIOBOOK_FILE_EXTENSIONS.include?(extension)
      handle_direct_audiobook_file_download(download, search_result, download_url, extension: extension, source_name: source_name)
    else
      raise "#{source_name} returned an unsupported audiobook direct download type"
    end
  end

  def handle_direct_audiobook_archive_download(download, search_result, download_url, source_name:)
    book = download.request.book
    base_path = SettingsService.get(:audiobook_output_path, default: "/audiobooks")
    destination_dir = direct_audiobook_archive_destination(book, base_path)

    Rails.logger.info "[DownloadJob] Downloading #{source_name} audiobook to: #{destination_dir}"
    ensure_book_available_for_direct_download!(book)
    mark_direct_download_active!(download)
    ensure_output_root!(base_path)
    file_service = DirectDownloadFileService.new(
      download: download,
      book: book,
      output_root: base_path,
      destination_path: destination_dir,
      book_path: destination_dir,
      kind: :directory
    )
    working_dir = file_service.create_staging!

    finalized = begin
      extracted = FileCopyService.create_private_directory(
        working_dir,
        root: base_path,
        prefix: "extracted-"
      )
      staging_dir = extracted.name
      staged_archive = FileCopyService.create_private_file(
        working_dir,
        root: base_path,
        prefix: "archive-",
        suffix: ".zip"
      )
      begin
        archive = staged_archive.io
        archive.binmode
        download_file_via_http(
          search_result,
          download_url,
          archive,
          max_bytes: MAX_DIRECT_AUDIOBOOK_DOWNLOAD_BYTES,
          download: download
        )
        verify_downloaded_zip!(archive)
        refresh_direct_download_heartbeat!(download)
        extract_zip_to_directory(
          archive,
          staging_dir,
          output_root: base_path,
          download: download
        )
        verify_extracted_audiobook!(staging_dir)
      ensure
        staged_archive.io.close unless staged_archive.io.closed?
      end

      refresh_direct_download_heartbeat!(download)
      # Archives extract to many files, so flat output has no single file to
      # track; the root is recorded and guarded against delete/zip by consumers.
      file_service.publish_directory_and_finalize!(staging_dir)
    ensure
      file_service.cleanup_after_run!
    end
    return unless finalized

    trigger_library_scan(book) if LibraryPlatformClient.configured?
    NotificationService.request_completed(download.request)
    track_request_event(download.request, "completed", download: download, message: "#{source_name} download completed")

    Rails.logger.info "[DownloadJob] #{source_name} download completed: #{destination_dir}"
  end

  def handle_direct_audiobook_file_download(download, search_result, download_url, extension:, source_name:)
    finalized = false
    book = download.request.book
    base_path = SettingsService.get(:audiobook_output_path, default: "/audiobooks")
    destination_dir = PathTemplateService.build_destination(book, base_path: base_path)
    filename = infer_audiobook_filename_from_url(download_url, search_result, extension)
    destination_path = File.join(destination_dir, filename)

    Rails.logger.info "[DownloadJob] Downloading #{source_name} audiobook file to: #{destination_path}"
    ensure_book_available_for_direct_download!(book)
    mark_direct_download_active!(download)
    ensure_output_root!(base_path)
    # Flat output shares destination_dir across books; track the file itself.
    book_path = PathTemplateService.flat_output?(book) ? destination_path : destination_dir
    file_service = DirectDownloadFileService.new(
      download: download,
      book: book,
      output_root: base_path,
      destination_path: destination_path,
      book_path: book_path,
      kind: :file
    )
    working_dir = file_service.create_staging!

    staged = FileCopyService.create_private_file(
      working_dir,
      root: base_path,
      prefix: "audiobook-",
      suffix: ".#{extension}"
    )
    begin
      staged_file = staged.io
      staged_file.binmode
      download_file_via_http(
        search_result,
        download_url,
        staged_file,
        max_bytes: MAX_DIRECT_AUDIOBOOK_DOWNLOAD_BYTES,
        download: download
      )
      verify_downloaded_audiobook_file!(staged_file)

      refresh_direct_download_heartbeat!(download)
      finalized = file_service.publish_file_and_finalize!(staged_file)
    ensure
      staged.io.close unless staged.io.closed?
    end
    file_service.cleanup_after_run!
    return unless finalized

    trigger_library_scan(book) if LibraryPlatformClient.configured?
    NotificationService.request_completed(download.request)
    track_request_event(download.request, "completed", download: download, message: "#{source_name} download completed")

    Rails.logger.info "[DownloadJob] #{source_name} download completed: #{destination_path}"
  rescue => e
    if finalized
      Rails.logger.warn "[DownloadJob] Post-completion action failed for download ##{download.id}: #{e.class}"
    else
      file_service&.cleanup_after_run!
      raise e
    end
  end

  def handle_direct_http_download(download, search_result, download_url)
    finalized = false
    book = download.request.book

    # Build destination path similar to how PostProcessingJob does it
    base_path = SettingsService.get(:ebook_output_path, default: "/ebooks")
    destination_dir = PathTemplateService.build_destination(book, base_path: base_path)

    # Infer filename from URL or search result
    filename = infer_filename_from_url(download_url, search_result)
    destination_path = File.join(destination_dir, filename)

    Rails.logger.info "[DownloadJob] Downloading directly to: #{destination_path}"
    ensure_book_available_for_direct_download!(book)
    mark_direct_download_active!(download)
    ensure_output_root!(base_path)
    # Flat output shares destination_dir across books; track the file itself.
    book_path = PathTemplateService.flat_output?(book) ? destination_path : destination_dir
    file_service = DirectDownloadFileService.new(
      download: download,
      book: book,
      output_root: base_path,
      destination_path: destination_path,
      book_path: book_path,
      kind: :file
    )
    working_dir = file_service.create_staging!

    expected_extension = infer_extension(download_url, search_result)
    staged = FileCopyService.create_private_file(
      working_dir,
      root: base_path,
      prefix: "ebook-",
      suffix: ".#{expected_extension}"
    )
    begin
      staged_file = staged.io
      staged_file.binmode
      download_file_via_http(search_result, download_url, staged_file, download: download)
      verify_downloaded_ebook!(staged_file, expected_extension: expected_extension)

      refresh_direct_download_heartbeat!(download)
      finalized = file_service.publish_file_and_finalize!(staged_file)
    ensure
      staged.io.close unless staged.io.closed?
    end
    file_service.cleanup_after_run!
    return unless finalized

    # Trigger library scan if configured
    trigger_library_scan(book) if LibraryPlatformClient.configured?

    # Send notification
    NotificationService.request_completed(download.request)
    track_request_event(download.request, "completed", download: download, message: "Direct download completed")

    Rails.logger.info "[DownloadJob] Direct download completed: #{destination_path}"
  rescue => e
    if finalized
      Rails.logger.warn "[DownloadJob] Post-completion action failed for download ##{download.id}: #{e.class}"
    else
      file_service&.cleanup_after_run!
      fail_direct_dispatch!(download, e, message: "Direct download failed: #{e.message}")
    end
  end

  def infer_filename_from_url(url, search_result)
    # Try to get filename from URL path
    uri = URI.parse(url)
    filename_from_url = File.basename(uri.path)

    # URL-decode the filename (converts %20 to space, %3A to colon, etc.)
    filename_from_url = URI.decode_www_form_component(filename_from_url) if filename_from_url.present?

    # If URL has a valid filename, use it after normalizing source-specific suffixes.
    inferred_extension = infer_extension(url, search_result)
    normalized_filename = normalize_url_filename(filename_from_url, inferred_extension)
    return normalized_filename if normalized_filename.present?

    # Fall back to constructing from search result
    book = search_result.request.book
    title = book.title.presence || "Unknown"
    author = book.author.presence || "Unknown"

    sanitize_filename("#{author} - #{title}.#{inferred_extension}")
  end

  def infer_extension(url, search_result)
    normalized_url = url.to_s.downcase

    # Check URL for extension hints
    return "epub" if normalized_url.include?("epub")
    return "pdf" if normalized_url.include?("pdf")
    if normalized_url.include?("mobi") || normalized_url.include?("kf8") || normalized_url.match?(/\.kindle(\.|[?#]|\z)/)
      return "mobi"
    end
    return "azw3" if normalized_url.include?("azw3")

    # Check search result title
    title = search_result.title.to_s.downcase
    return "epub" if title.include?("epub")
    return "pdf" if title.include?("pdf")
    return "mobi" if title.include?("mobi")
    return "azw3" if title.include?("azw3")

    # Default to epub
    "epub"
  end

  def infer_audiobook_extension(url, search_result)
    extension = extension_from_url(url, DIRECT_AUDIOBOOK_EXTENSIONS)
    return extension if extension.present?

    title = search_result.title.to_s.downcase
    DIRECT_AUDIOBOOK_EXTENSIONS.find { |candidate| title_format_hint?(title, candidate) }
  end

  def title_format_hint?(title, extension)
    escaped = Regexp.escape(extension)
    return title.match?(/[\[\(.]#{escaped}[\]\)]?(\b|\z)/) if AMBIGUOUS_AUDIOBOOK_EXTENSIONS.include?(extension)

    title.match?(/\b#{escaped}\b/)
  end

  def infer_audiobook_filename_from_url(url, search_result, extension)
    filename_from_url = filename_from_url(url)
    return sanitize_filename(filename_from_url) if filename_from_url.present? &&
      File.extname(filename_from_url).delete(".").downcase == extension

    book = search_result.request.book
    title = book.title.presence || "Unknown"
    author = book.author.presence || "Unknown"
    sanitize_filename("#{author} - #{title}.#{extension}")
  end

  def direct_audiobook_archive_destination(book, base_path)
    destination = PathTemplateService.build_destination(book, base_path: base_path)
    return destination unless PathTemplateService.flat_output?(book)

    # A multi-file archive cannot be atomically merged into a shared flat
    # output root. Give it one deterministic per-title directory instead.
    folder = sanitize_filename(
      "#{book.author.presence || 'Unknown Author'} - #{book.title.presence || 'Unknown'}"
    )
    File.join(base_path, folder)
  end

  def extension_from_url(url, allowed_extensions)
    uri = URI.parse(normalize_direct_download_url(url))
    extension = File.extname(uri.path).delete(".").downcase
    return extension if allowed_extensions.include?(extension)

    nil
  rescue URI::InvalidURIError
    nil
  end

  def torrent_download_url?(url)
    return true if url.to_s.start_with?("magnet:")

    File.extname(URI.parse(url.to_s).path).casecmp?(".torrent")
  rescue URI::InvalidURIError
    false
  end

  def filename_from_url(url)
    uri = URI.parse(normalize_direct_download_url(url))
    filename = File.basename(uri.path)
    URI.decode_www_form_component(filename) if filename.present?
  rescue URI::InvalidURIError
    nil
  end

  def normalize_url_filename(filename, inferred_extension)
    return nil if filename.blank?

    current_extension = File.extname(filename).delete(".").downcase
    return sanitize_filename(filename) if DIRECT_EBOOK_EXTENSIONS.include?(current_extension)
    return nil unless filename.include?(".") && DIRECT_EBOOK_EXTENSIONS.include?(inferred_extension)
    return nil unless url_filename_extension_hint?(filename, inferred_extension)

    base = File.basename(filename, ".*")
    base = base.sub(/\.epub3\z/i, "") if inferred_extension == "epub"
    base = base.sub(/\.kf8\z/i, "") if inferred_extension == "mobi"
    base = base.sub(/\.kindle\z/i, "") if inferred_extension == "mobi"
    base = base.sub(/\.#{Regexp.escape(inferred_extension)}\z/i, "")
    return nil if base.blank?

    sanitize_filename("#{base}.#{inferred_extension}")
  end

  def url_filename_extension_hint?(filename, inferred_extension)
    normalized = filename.to_s.downcase
    extension = Regexp.escape(inferred_extension)

    return true if normalized.match?(/\.#{extension}(\.|\z)/)
    return true if inferred_extension == "epub" && normalized.match?(/\.epub3(\.|\z)/)
    return true if inferred_extension == "mobi" && normalized.match?(/\.(kf8|kindle)(\.|\z)/)

    false
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

  def download_file_via_http(search_result, url, destination, max_bytes: MAX_DIRECT_DOWNLOAD_BYTES, download: nil)
    endpoint = validate_direct_download_url!(url, search_result)
    unless destination.respond_to?(:write) && destination.respond_to?(:stat)
      raise ArgumentError, "Direct downloads must target an already-open private staging file"
    end

    Rails.logger.info "[DownloadJob] Starting HTTP download..."

    bytes_written = 0
    redirects_followed = 0
    download_complete = false
    last_heartbeat_at = refresh_direct_download_heartbeat!(download) if download

    loop do
      response_handled = false

      Net::HTTP.start(
        endpoint.host,
        endpoint.port,
        use_ssl: endpoint.use_ssl?,
        ipaddr: endpoint.ipaddr,
        open_timeout: 30,
        read_timeout: 300
      ) do |http|
        request = Net::HTTP::Get.new(endpoint.uri)
        request["User-Agent"] = "Shelfarr/1.0"

        http.request(request) do |response|
          if response.is_a?(Net::HTTPRedirection)
            redirects_followed += 1
            raise "Direct download exceeded redirect limit" if redirects_followed > MAX_DIRECT_DOWNLOAD_REDIRECTS

            location = response["Location"]
            raise "Direct download redirect missing Location" if location.blank?

            endpoint = validate_direct_download_url!(URI.join(endpoint.uri, normalize_direct_download_url(location)).to_s, search_result)
            Rails.logger.info "[DownloadJob] Following HTTP redirect to #{endpoint.host}"
            response_handled = true
            next
          end

          unless response.is_a?(Net::HTTPSuccess)
            message = "Direct download failed with status #{response.code}"
            raise DirectDownloadError, message if response.code.to_i == 429 || response.code.to_i >= 500

            raise message
          end

          validate_direct_download_response_headers!(
            content_type: response["Content-Type"],
            content_length: response["Content-Length"],
            max_bytes: max_bytes
          )

          destination.rewind
          destination.truncate(0)
          bytes_written = 0
          response.read_body do |chunk|
            if download && last_heartbeat_at < DIRECT_DOWNLOAD_HEARTBEAT_INTERVAL.ago
              last_heartbeat_at = refresh_direct_download_heartbeat!(download)
            end
            bytes_written += chunk.bytesize
            raise "Direct download exceeds size limit of #{max_bytes / 1.megabyte} MB" if bytes_written > max_bytes

            destination.write(chunk)
          end
          destination.flush
          destination.fsync
          destination.rewind

          response_handled = true
          download_complete = true
        end
      end

      break if download_complete
      next if response_handled

      raise "Direct download failed without a response"
    end

    file_size = destination.stat.size
    Rails.logger.info "[DownloadJob] Downloaded #{(file_size / 1024.0 / 1024.0).round(2)} MB"
  rescue SocketError, IOError, EOFError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
    raise DirectDownloadError, "Direct download request failed: #{e.message}"
  end

  def mark_direct_download_active!(download)
    now = Time.current
    claimed = Download
      .where(id: download.id, status: Download.statuses[:downloading], download_type: "dispatching")
      .update_all(download_type: "direct", updated_at: now)
    raise DirectDownloadError, "Direct download is no longer active" unless claimed == 1

    download.download_type = "direct"
    download.updated_at = now
  end

  def refresh_direct_download_heartbeat!(download)
    now = Time.current
    refreshed = Download
      .where(id: download.id, status: Download.statuses[:downloading], download_type: "direct")
      .update_all(updated_at: now)
    raise DirectDownloadError, "Direct download is no longer active" unless refreshed == 1

    download.updated_at = now
    now
  end

  def validate_direct_download_url!(url, search_result = nil)
    OutboundUrlGuard.validate!(
      normalize_direct_download_url(url),
      allow_private: allow_private_download?(search_result)
    )
  rescue OutboundUrlGuard::BlockedUrlError => e
    raise "Invalid direct download URL: #{e.message}"
  end

  def allow_private_download?(search_result)
    return false unless search_result&.from_custom_provider?

    search_result.acquisition_provider&.allow_private_network? || false
  end

  def validate_dispatch_url!(url, search_result)
    return url if url.to_s.start_with?("magnet:")

    OutboundUrlGuard.validate!(url, allow_private: allow_private_download?(search_result))
    url
  rescue OutboundUrlGuard::BlockedUrlError => e
    raise CustomAcquisitionProviderClient::UnusableArtifactError, "Refused download URL from custom provider: #{e.message}"
  end

  def normalize_direct_download_url(url)
    url.to_s.strip.gsub(" ", "%20")
  end

  def validate_direct_download_response_headers!(content_type:, content_length:, max_bytes: MAX_DIRECT_DOWNLOAD_BYTES)
    normalized_content_type = content_type.to_s.split(";").first.to_s.downcase

    if normalized_content_type.present? &&
        (normalized_content_type.start_with?("text/") ||
         normalized_content_type.include?("html") ||
         normalized_content_type.include?("json") ||
         normalized_content_type.include?("xml"))
      raise "Direct download returned unexpected content type: #{normalized_content_type}"
    end

    length = content_length.to_i if content_length.present?
    if length.present? && length > max_bytes
      raise "Direct download exceeds size limit of #{max_bytes / 1.megabyte} MB"
    end
  end

  def verify_downloaded_ebook!(path, expected_extension: nil)
    with_regular_download_io(path) do |file|
      file_size = file.stat.size
      raise "Downloaded file is empty" if file_size.zero?

      head = read_download_head(file, [ 512, file_size ].min)
      lowered = head.downcase
      if lowered.include?("<html") || lowered.include?("<!doctype")
        raise "Downloaded file is an HTML page, not an ebook"
      end

      case expected_extension.to_s.downcase
      when "epub"
        raise "Downloaded file is not a valid EPUB" unless head.start_with?("PK\x03\x04")
      when "pdf"
        raise "Downloaded file is not a valid PDF" unless head.start_with?("%PDF")
      when "mobi"
        mobi_signature = read_download_head(file, [ 68, file_size ].min).byteslice(60, 8)
        raise "Downloaded file is not a valid MOBI" unless mobi_signature == "BOOKMOBI"
      end
    end
  rescue Errno::ENOENT => e
    raise "Downloaded file is missing: #{e.message}"
  end

  def verify_downloaded_zip!(path)
    with_regular_download_io(path) do |file|
      file_size = file.stat.size
      raise "Downloaded file is empty" if file_size.zero?

      head = read_download_head(file, [ 512, file_size ].min)
      lowered = head.downcase
      if lowered.include?("<html") || lowered.include?("<!doctype")
        raise "Downloaded file is an HTML page, not an audiobook archive"
      end

      raise "Downloaded file is not a valid ZIP archive" unless head.start_with?("PK\x03\x04")
    end
  rescue Errno::ENOENT => e
    raise "Downloaded file is missing: #{e.message}"
  end

  def verify_downloaded_audiobook_file!(path)
    with_regular_download_io(path) do |file|
      file_size = file.stat.size
      raise "Downloaded file is empty" if file_size.zero?

      head = read_download_head(file, [ 512, file_size ].min)
      lowered = head.downcase
      if lowered.include?("<html") || lowered.include?("<!doctype")
        raise "Downloaded file is an HTML page, not an audiobook"
      end
    end
  rescue Errno::ENOENT => e
    raise "Downloaded file is missing: #{e.message}"
  end

  def with_regular_download_io(path_or_io)
    if path_or_io.respond_to?(:stat) && path_or_io.respond_to?(:read)
      raise "Downloaded path is not a regular file" unless path_or_io.stat.file?

      return yield path_or_io
    end

    File.open(
      path_or_io,
      File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    ) do |file|
      raise "Downloaded path is not a regular file" unless file.stat.file?

      yield file
    end
  rescue Errno::ELOOP, Errno::ENXIO, Errno::ENODEV
    raise "Downloaded path is not a safe regular file"
  end

  def read_download_head(file, length)
    position = file.pos
    file.rewind
    file.read(length).to_s
  ensure
    file.seek(position, IO::SEEK_SET) if position
  end

  def extract_zip_to_directory(source, destination_dir, output_root:, download: nil)
    unless source.respond_to?(:stat) && source.respond_to?(:read)
      raise ArgumentError, "Direct ZIP extraction requires an already-open staging file"
    end

    heartbeat = -> { refresh_direct_download_heartbeat!(download) } if download
    DirectDownloadArchiveExtractor.new(
      source: source,
      destination: destination_dir,
      output_root: output_root,
      max_bytes: MAX_DIRECT_AUDIOBOOK_DOWNLOAD_BYTES,
      max_entries: MAX_DIRECT_ARCHIVE_ENTRIES,
      heartbeat: heartbeat
    ).extract!
  end

  def verify_extracted_audiobook!(destination_dir)
    audio_files = Dir.glob(File.join(destination_dir, "**", "*"), File::FNM_DOTMATCH).select do |path|
      File.file?(path) && DIRECT_AUDIOBOOK_FILE_EXTENSIONS.include?(File.extname(path).delete(".").downcase)
    end
    return if audio_files.any? && audio_files.all? { |path| valid_audiobook_signature?(path) }

    raise "Downloaded audiobook archive does not contain valid supported audio files"
  end

  def valid_audiobook_signature?(path)
    head = File.binread(path, 12)
    extension = File.extname(path).delete(".").downcase

    case extension
    when "mp3"
      head.start_with?("ID3") || (head.getbyte(0) == 0xff && (head.getbyte(1).to_i & 0xe0) == 0xe0)
    when "m4b", "m4a"
      head.byteslice(4, 4) == "ftyp"
    when "aac"
      head.start_with?("ADIF") || (head.getbyte(0) == 0xff && (head.getbyte(1).to_i & 0xf0) == 0xf0)
    when "flac"
      head.start_with?("fLaC")
    when "ogg", "opus"
      head.start_with?("OggS")
    else
      false
    end
  rescue EOFError, Errno::ENOENT
    false
  end

  def ensure_book_available_for_direct_download!(book)
    return unless book.reload.acquisition_blocked?

    raise BookAcquisitionConflictError,
      "Another acquisition already claimed this title; its existing library file was preserved"
  end

  def ensure_output_root!(base_path)
    root = Pathname(base_path).expand_path
    return FileCopyService.ensure_directory(root.to_s, root: root.to_s) if root.directory?

    existing_parent = root.parent
    existing_parent = existing_parent.parent until existing_parent.exist? || existing_parent.root?
    stat = File.lstat(existing_parent)
    unless stat.directory?
      raise FileCopyService::UnsafePathError, "Configured library path has an unsafe parent"
    end

    FileCopyService.ensure_directory(root.to_s, root: existing_parent.to_s)
  end

  def trigger_library_scan(book)
    lib_id = SettingsService.library_id_for_book(book)

    return unless lib_id.present?

    LibraryPlatformClient.scan_library(lib_id)
    Rails.logger.info "[DownloadJob] Triggered #{LibraryPlatformClient.display_name} library scan for #{book.book_type}"
  rescue LibraryPlatformClient::Error => e
    Rails.logger.warn "[DownloadJob] Failed to trigger scan: #{e.message}"
  end

  def send_to_torrent_client(download, search_result, download_url)
    # Select torrent client
    client_record = DownloadClientSelector.for_torrent
    client = client_record.adapter

    Rails.logger.info "[DownloadJob] Using client '#{client_record.name}' for download ##{download.id}"

    # add_torrent now returns the hash directly (or nil on failure)
    torrent_hash = if search_result.from_anna_archive?
      client.add_torrent(download_url, validate_source_url: true)
    else
      client.add_torrent(download_url)
    end

    if torrent_hash.present?
      finalize_standard_dispatch!(
        download,
        search_result,
        client,
        client_record,
        torrent_hash,
        download_type: "torrent"
      )
    else
      fail_standard_dispatch!(download, search_result, client_record, download_type: "torrent")
    end
  end

  def send_to_usenet_client(download, search_result, nzb_url)
    client_record = DownloadClient.usenet_clients.enabled.by_priority.find(&:test_connection)
    raise DownloadClientSelector::NoClientAvailableError, "No usenet client available (all failed connection test)" unless client_record

    client = client_record.adapter
    Rails.logger.info "[DownloadJob] Using client '#{client_record.name}' for custom usenet download ##{download.id}"

    result = client.add_torrent(nzb_url, nzbname: build_usenet_job_name(search_result))
    external_id = result.is_a?(Hash) ? result["nzo_ids"]&.first : nil

    if external_id.present?
      finalize_standard_dispatch!(
        download,
        search_result,
        client,
        client_record,
        external_id,
        download_type: "usenet"
      )
    else
      fail_standard_dispatch!(download, search_result, client_record, download_type: "usenet")
    end
  end

  def handle_standard_download(download, search_result)
    unless search_result.downloadable?
      Rails.logger.error "[DownloadJob] Search result has no download link for download ##{download.id}"
      track_request_event(download.request, "dispatch_failed", download: download, message: "Selected result has no download link", level: :error)
      download.update!(status: :failed)
      download.request.handle_download_failure!(download, reason: "Selected result has no download link")
      return
    end

    download_link = search_result.download_link
    validate_manual_nzb_dispatch_url!(download_link) if search_result.from_manual_nzb?

    # Select best available client based on download type and priority
    client_record = DownloadClientSelector.for_download(search_result)
    client = client_record.adapter
    is_usenet = search_result.usenet?

    Rails.logger.info "[DownloadJob] Using client '#{client_record.name}' for download ##{download.id}"

    Rails.logger.info "[DownloadJob] Download link type: #{is_usenet ? 'usenet' : 'torrent'}, length: #{download_link.to_s.length} chars"
    if search_result.from_manual_nzb?
      Rails.logger.debug "[DownloadJob] Full download URL: [REDACTED MANUAL NZB URL]"
    else
      Rails.logger.debug "[DownloadJob] Full download URL: #{UrlRedactor.redact(download_link)}"
    end

    if is_usenet
      # SABnzbd returns a hash with nzo_ids
      result = client.add_torrent(
        download_link,
        nzbname: build_usenet_job_name(search_result),
        sensitive_url: search_result.from_manual_nzb?
      )
      external_id = result.is_a?(Hash) ? result["nzo_ids"]&.first : nil
      success = external_id.present?
    else
      # qBittorrent now returns the torrent hash directly
      external_id = client.add_torrent(download_link)
      success = external_id.present?
    end

    if success
      finalize_standard_dispatch!(
        download,
        search_result,
        client,
        client_record,
        external_id,
        download_type: is_usenet ? "usenet" : "torrent"
      )
    else
      fail_standard_dispatch!(
        download,
        search_result,
        client_record,
        download_type: is_usenet ? "usenet" : "torrent"
      )
    end
  end

  def claim_dispatch!(download, search_result)
    claimed = false

    download.request.with_lock do
      download.reload
      search_result.reload
      next unless download.queued?

      download.update!(status: :downloading, download_type: "dispatching")
      claimed = true
    end

    claimed
  rescue ActiveRecord::RecordNotFound
    false
  end

  def finalize_standard_dispatch!(download, search_result, client, client_record, external_id, download_type:)
    finalized = false

    begin
      finalized = download.request.with_lock do
        next false unless current_standard_dispatch?(download, search_result)

        check_for_duplicate_external_id(external_id, download.id)
        download.update!(
          download_client: client_record,
          external_id: external_id,
          download_type: download_type
        )
        track_request_event(
          download.request,
          "dispatched",
          download: download,
          message: "Sent #{download_type} download to #{client_record.name}",
          details: {
            client_name: client_record.name,
            download_type: download_type,
            external_id: external_id
          }
        )
        true
      end
    rescue ActiveRecord::RecordNotFound
      finalized = false
    ensure
      remove_stale_client_dispatch(client, client_record, external_id, download.id) unless finalized
    end

    Rails.logger.info "[DownloadJob] Successfully added #{download_type} for download ##{download.id}, external_id: #{external_id}" if finalized
    finalized
  end

  def fail_standard_dispatch!(download, search_result, client_record, download_type:)
    failed = false

    download.request.with_lock do
      next unless current_standard_dispatch?(download, search_result)

      track_request_event(
        download.request,
        "dispatch_failed",
        download: download,
        message: "Client did not return an external ID",
        level: :error,
        details: {
          client_name: client_record.name,
          download_type: download_type
        }
      )
      download.update!(status: :failed)
      download.request.handle_download_failure!(download, reason: "Failed to add to #{client_record.name}")
      failed = true
    end

    Rails.logger.error "[DownloadJob] Failed to add download ##{download.id}" if failed
    failed
  rescue ActiveRecord::RecordNotFound
    false
  end

  def current_standard_dispatch?(download, search_result)
    download.reload
    search_result.reload
    download.downloading? && download.download_type == "dispatching" && download.external_id.blank?
  end

  def fail_direct_dispatch!(download, error, message:)
    handled = download.request.with_lock do
      download.reload
      next false unless download.downloading? && download.download_type.in?([ "dispatching", "direct" ])

      Rails.logger.error "[DownloadJob] #{message}"
      Rails.logger.error error.backtrace.first(5).join("\n") if error.backtrace
      track_request_event(download.request, "failed", download: download, message: error.message, level: :error)
      download.update!(status: :failed)
      handle_direct_download_failure(download, error, message: message)
      true
    end

    handled
  rescue ActiveRecord::RecordNotFound
    false
  end

  def remove_stale_client_dispatch(client, client_record, external_id, download_id)
    removed = client.remove_torrent(external_id, delete_files: true)
    if removed
      Rails.logger.info "[DownloadJob] Removed stale client dispatch for replaced download ##{download_id}"
    else
      Rails.logger.warn "[DownloadJob] Client did not remove stale dispatch for replaced download ##{download_id}; scheduling cleanup"
      enqueue_stale_client_cleanup(client_record.id, external_id, download_id)
    end
  rescue StandardError => e
    Rails.logger.warn "[DownloadJob] Failed to remove stale dispatch for replaced download ##{download_id}: #{e.class}; scheduling cleanup"
    enqueue_stale_client_cleanup(client_record.id, external_id, download_id)
  end

  def enqueue_stale_client_cleanup(client_id, external_id, download_id)
    StaleClientDispatchCleanupJob.perform_later(client_id, external_id)
  rescue StandardError => e
    Rails.logger.error "[DownloadJob] Failed to enqueue stale dispatch cleanup for download ##{download_id}: #{e.class}"
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

  def build_usenet_job_name(search_result)
    book = search_result.request.book
    parts = [ book.author.to_s.strip.presence, book.title.to_s.strip.presence ].compact
    return parts.join(" - ") if parts.any?

    search_result.title.to_s.strip.presence
  end

  def validate_manual_nzb_dispatch_url!(url)
    # Manual URLs are admin-provided and may intentionally target a home-lab
    # service, but metadata, link-local, multicast, and reserved destinations
    # should never be delegated to a download client.
    OutboundUrlGuard.validate!(url, allow_private: true)
  rescue OutboundUrlGuard::BlockedUrlError
    raise DownloadClients::Base::Error, "Manual NZB URL points to a blocked or invalid destination"
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
