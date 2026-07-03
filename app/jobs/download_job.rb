# frozen_string_literal: true

require "net/http"
require "uri"
require "tempfile"

class DownloadJob < ApplicationJob
  queue_as :default

  MAX_DIRECT_DOWNLOAD_BYTES = 512.megabytes
  MAX_DIRECT_AUDIOBOOK_DOWNLOAD_BYTES = 2.gigabytes
  MAX_DIRECT_DOWNLOAD_REDIRECTS = 5
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
    rescue LibrivoxClient::Error => e
      Rails.logger.error "[DownloadJob] LibriVox error for download ##{download.id}: #{e.message}"
      track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
      download.update!(status: :failed)
      download.request.mark_for_attention!("LibriVox error: #{e.message}")
    rescue GutenbergClient::Error => e
      Rails.logger.error "[DownloadJob] Project Gutenberg error for download ##{download.id}: #{e.message}"
      track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
      download.update!(status: :failed)
      download.request.mark_for_attention!("Project Gutenberg error: #{e.message}")
    rescue CustomAcquisitionProviderClient::Error => e
      Rails.logger.error "[DownloadJob] Custom provider error for download ##{download.id}: #{e.message}"
      track_request_event(download.request, "dispatch_failed", download: download, message: e.message, level: :error)
      download.update!(status: :failed)
      download.request.mark_for_attention!("Custom provider error: #{e.message}")
    end
  end

  private

  def handle_anna_archive_download(download, search_result)
    # Fetch actual download URL from Anna's Archive API
    md5 = search_result.guid
    Rails.logger.info "[DownloadJob] Fetching download URL from Anna's Archive for MD5: #{md5}"

    download_url = AnnaArchiveClient.get_download_url(md5)
    Rails.logger.info "[DownloadJob] Got download URL: #{UrlRedactor.redact(download_url).truncate(100)}"

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

  def handle_gutenberg_download(download, search_result)
    raise GutenbergClient::Error, "Selected Project Gutenberg result is missing a download URL" if search_result.download_url.blank?

    handle_direct_http_download(download, search_result, search_result.download_url)
  end

  def handle_librivox_download(download, search_result)
    raise LibrivoxClient::Error, "Selected LibriVox result is missing a download URL" if search_result.download_url.blank?

    handle_direct_audiobook_archive_download(download, search_result, search_result.download_url, source_name: "LibriVox")
  rescue => e
    Rails.logger.error "[DownloadJob] LibriVox download failed: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    track_request_event(download.request, "failed", download: download, message: e.message, level: :error)
    download.update!(status: :failed)
    download.request.mark_for_attention!("LibriVox download failed: #{e.message}")
  end

  def handle_custom_provider_download(download, search_result)
    provider = search_result.acquisition_provider
    raise CustomAcquisitionProviderClient::ResponseError, "Selected custom provider result is missing its provider" unless provider&.enabled?

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
      raise CustomAcquisitionProviderClient::ResponseError, "Unsupported custom provider artifact type: #{acquisition.download_type}"
    end
  rescue CustomAcquisitionProviderClient::Error
    raise
  rescue => e
    Rails.logger.error "[DownloadJob] Custom provider download failed: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    track_request_event(download.request, "failed", download: download, message: e.message, level: :error)
    download.update!(status: :failed)
    download.request.mark_for_attention!("Custom provider download failed: #{e.message}")
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
    destination_dir = PathTemplateService.build_destination(book, base_path: base_path)

    Rails.logger.info "[DownloadJob] Downloading #{source_name} audiobook to: #{destination_dir}"
    FileUtils.mkdir_p(destination_dir)

    Tempfile.create([ "shelfarr-audiobook-", ".zip" ]) do |archive|
      archive.binmode
      download_file_via_http(
        search_result,
        download_url,
        archive.path,
        max_bytes: MAX_DIRECT_AUDIOBOOK_DOWNLOAD_BYTES
      )
      verify_downloaded_zip!(archive.path)
      extract_zip_to_directory(archive.path, destination_dir)
    end

    download.update!(
      status: :completed,
      download_path: destination_dir,
      download_type: "direct"
    )

    # Archives extract to many files, so flat output has no single file to
    # track; the root is recorded and guarded against delete/zip by consumers
    book.update!(file_path: destination_dir)
    download.request.complete!
    trigger_library_scan(book) if LibraryPlatformClient.configured?
    NotificationService.request_completed(download.request)
    track_request_event(download.request, "completed", download: download, message: "#{source_name} download completed")

    Rails.logger.info "[DownloadJob] #{source_name} download completed: #{destination_dir}"
  end

  def handle_direct_audiobook_file_download(download, search_result, download_url, extension:, source_name:)
    book = download.request.book
    base_path = SettingsService.get(:audiobook_output_path, default: "/audiobooks")
    destination_dir = PathTemplateService.build_destination(book, base_path: base_path)
    filename = infer_audiobook_filename_from_url(download_url, search_result, extension)
    destination_path = File.join(destination_dir, filename)

    Rails.logger.info "[DownloadJob] Downloading #{source_name} audiobook file to: #{destination_path}"
    FileUtils.mkdir_p(destination_dir)

    download_file_via_http(
      search_result,
      download_url,
      destination_path,
      max_bytes: MAX_DIRECT_AUDIOBOOK_DOWNLOAD_BYTES
    )
    verify_downloaded_audiobook_file!(destination_path)

    download.update!(
      status: :completed,
      download_path: destination_path,
      download_type: "direct"
    )

    # Flat output shares destination_dir across books; track the file itself
    book.update!(file_path: PathTemplateService.flat_output?(book) ? destination_path : destination_dir)
    download.request.complete!
    trigger_library_scan(book) if LibraryPlatformClient.configured?
    NotificationService.request_completed(download.request)
    track_request_event(download.request, "completed", download: download, message: "#{source_name} download completed")

    Rails.logger.info "[DownloadJob] #{source_name} download completed: #{destination_path}"
  rescue => e
    FileUtils.rm_f(destination_path) if defined?(destination_path) && destination_path.present?
    raise e
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
    expected_extension = infer_extension(download_url, search_result)
    download_file_via_http(search_result, download_url, destination_path)
    verify_downloaded_ebook!(destination_path, expected_extension: expected_extension)

    # Update download record as completed
    download.update!(
      status: :completed,
      download_path: destination_path,
      download_type: "direct"
    )

    # Update book with file path
    # Flat output shares destination_dir across books; track the file itself
    book.update!(file_path: PathTemplateService.flat_output?(book) ? destination_path : destination_dir)

    # Complete the request
    download.request.complete!

    # Trigger library scan if configured
    trigger_library_scan(book) if LibraryPlatformClient.configured?

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

  def extension_from_url(url, allowed_extensions)
    uri = URI.parse(normalize_direct_download_url(url))
    extension = File.extname(uri.path).delete(".").downcase
    return extension if allowed_extensions.include?(extension)

    nil
  rescue URI::InvalidURIError
    nil
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

  def download_file_via_http(search_result, url, destination, max_bytes: MAX_DIRECT_DOWNLOAD_BYTES)
    endpoint = validate_direct_download_url!(url, search_result)

    Rails.logger.info "[DownloadJob] Starting HTTP download..."

    bytes_written = 0
    redirects_followed = 0
    download_complete = false

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

          raise "Direct download failed with status #{response.code}" unless response.is_a?(Net::HTTPSuccess)

          validate_direct_download_response_headers!(
            content_type: response["Content-Type"],
            content_length: response["Content-Length"],
            max_bytes: max_bytes
          )

          File.open(destination, "wb") do |dest|
            response.read_body do |chunk|
              bytes_written += chunk.bytesize
              raise "Direct download exceeds size limit of #{max_bytes / 1.megabyte} MB" if bytes_written > max_bytes

              dest.write(chunk)
            end
          end

          response_handled = true
          download_complete = true
        end
      end

      break if download_complete
      next if response_handled

      raise "Direct download failed without a response"
    end

    file_size = File.size(destination)
    Rails.logger.info "[DownloadJob] Downloaded #{(file_size / 1024.0 / 1024.0).round(2)} MB"
  rescue SocketError, IOError, EOFError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
    raise "Direct download request failed: #{e.message}"
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
    raise CustomAcquisitionProviderClient::ResponseError, "Refused download URL from custom provider: #{e.message}"
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
    raise "Downloaded file does not exist" unless File.exist?(path)

    file_size = File.size(path)
    raise "Downloaded file is empty" if file_size.zero?

    head = File.binread(path, [ 512, file_size ].min)
    lowered = head.downcase
    if lowered.include?("<html") || lowered.include?("<!doctype")
      FileUtils.rm_f(path)
      raise "Downloaded file is an HTML page, not an ebook"
    end

    case expected_extension.to_s.downcase
    when "epub"
      raise "Downloaded file is not a valid EPUB" unless head.start_with?("PK\x03\x04")
    when "pdf"
      raise "Downloaded file is not a valid PDF" unless head.start_with?("%PDF")
    when "mobi"
      mobi_signature = File.binread(path, [ 68, file_size ].min).byteslice(60, 8)
      raise "Downloaded file is not a valid MOBI" unless mobi_signature == "BOOKMOBI"
    end
  rescue Errno::ENOENT => e
    raise "Downloaded file is missing: #{e.message}"
  end

  def verify_downloaded_zip!(path)
    raise "Downloaded file does not exist" unless File.exist?(path)

    file_size = File.size(path)
    raise "Downloaded file is empty" if file_size.zero?

    head = File.binread(path, [ 512, file_size ].min)
    lowered = head.downcase
    if lowered.include?("<html") || lowered.include?("<!doctype")
      FileUtils.rm_f(path)
      raise "Downloaded file is an HTML page, not an audiobook archive"
    end

    raise "Downloaded file is not a valid ZIP archive" unless head.start_with?("PK\x03\x04")
  rescue Errno::ENOENT => e
    raise "Downloaded file is missing: #{e.message}"
  end

  def verify_downloaded_audiobook_file!(path)
    raise "Downloaded file does not exist" unless File.exist?(path)

    file_size = File.size(path)
    raise "Downloaded file is empty" if file_size.zero?

    head = File.binread(path, [ 512, file_size ].min)
    lowered = head.downcase
    if lowered.include?("<html") || lowered.include?("<!doctype")
      FileUtils.rm_f(path)
      raise "Downloaded file is an HTML page, not an audiobook"
    end
  rescue Errno::ENOENT => e
    raise "Downloaded file is missing: #{e.message}"
  end

  def extract_zip_to_directory(zip_path, destination_dir)
    require "zip"

    destination_root = File.expand_path(destination_dir)
    extracted_files = 0

    Zip::File.open(zip_path) do |zipfile|
      zipfile.each do |entry|
        next if entry.directory?

        target = File.expand_path(File.join(destination_root, entry.name))
        unless target.start_with?("#{destination_root}#{File::SEPARATOR}")
          raise "ZIP archive contains an unsafe path: #{entry.name}"
        end

        FileUtils.mkdir_p(File.dirname(target))
        entry.get_input_stream do |input|
          File.open(target, "wb") { |output| IO.copy_stream(input, output) }
        end
        extracted_files += 1
      end
    end

    raise "ZIP archive did not contain any files" if extracted_files.zero?
  rescue Zip::Error => e
    raise "Failed to extract audiobook archive: #{e.message}"
  end

  def trigger_library_scan(book)
    lib_id = if book.audiobook?
      SettingsService.get(:audiobookshelf_audiobook_library_id)
    else
      SettingsService.get(:audiobookshelf_ebook_library_id)
    end

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

  def send_to_usenet_client(download, search_result, nzb_url)
    client_record = DownloadClient.usenet_clients.enabled.by_priority.find(&:test_connection)
    raise DownloadClientSelector::NoClientAvailableError, "No usenet client available (all failed connection test)" unless client_record

    client = client_record.adapter
    Rails.logger.info "[DownloadJob] Using client '#{client_record.name}' for custom usenet download ##{download.id}"

    result = client.add_torrent(nzb_url, nzbname: build_usenet_job_name(search_result))
    external_id = result.is_a?(Hash) ? result["nzo_ids"]&.first : nil

    if external_id.present?
      check_for_duplicate_external_id(external_id, download.id)

      download.update!(
        status: :downloading,
        download_client: client_record,
        external_id: external_id,
        download_type: "usenet"
      )
      track_request_event(
        download.request,
        "dispatched",
        download: download,
        message: "Sent usenet download to #{client_record.name}",
        details: {
          client_name: client_record.name,
          download_type: "usenet",
          external_id: external_id
        }
      )
    else
      track_request_event(
        download.request,
        "dispatch_failed",
        download: download,
        message: "Client did not return an external ID",
        level: :error,
        details: { client_name: client_record.name, download_type: "usenet" }
      )
      download.update!(status: :failed)
      download.request.mark_for_attention!("Failed to add to #{client_record.name}")
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
    Rails.logger.debug "[DownloadJob] Full download URL: #{UrlRedactor.redact(download_link)}"

    if is_usenet
      # SABnzbd returns a hash with nzo_ids
      result = client.add_torrent(download_link, nzbname: build_usenet_job_name(search_result))
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

  def build_usenet_job_name(search_result)
    book = search_result.request.book
    parts = [ book.author.to_s.strip.presence, book.title.to_s.strip.presence ].compact
    return parts.join(" - ") if parts.any?

    search_result.title.to_s.strip.presence
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
