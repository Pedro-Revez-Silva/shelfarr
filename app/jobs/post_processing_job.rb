# frozen_string_literal: true

# Copies completed downloads to library folder and triggers library scan.
# Files are COPIED (not moved) to preserve seeding for torrent downloads.
# Usenet downloads are removed from the client after successful import.
class PostProcessingJob < ApplicationJob
  EBOOK_FILE_EXTENSIONS = %w[epub pdf mobi azw azw3 cbz cbr djvu].freeze
  EBOOK_SIDECAR_EXTENSIONS = %w[jpg jpeg png webp opf nfo txt].freeze
  EBOOK_ALLOWED_EXTENSIONS = (EBOOK_FILE_EXTENSIONS + EBOOK_SIDECAR_EXTENSIONS).freeze

  queue_as :default

  def perform(download_id, source_path_retry_count = 0)
    download = Download.find_by(id: download_id)
    return unless download&.completed?

    request = download.request
    book = request.book

    Rails.logger.info "[PostProcessingJob] Starting post-processing for download #{download.id} (#{book.title})"

    request.update!(status: :processing)

    begin
      destination = build_destination_path(book, download)
      source_path = remap_download_path(download.download_path, download)
      if source_path_unavailable?(source_path)
        return retry_source_path_later(download, request, source_path, source_path_retry_count)
      end

      copy_files(source_path, destination, book: book)
      cleanup_usenet_download(download)

      book.update!(file_path: destination)
      request.complete!

      # Pre-create zip for directories (audiobooks) so download is instant
      pre_create_download_zip(book, destination) if File.directory?(destination)

      trigger_library_scan(book) if AudiobookshelfClient.configured?

      NotificationService.request_completed(request)

      Rails.logger.info "[PostProcessingJob] Completed processing for #{book.title} -> #{destination}"
    rescue => e
      Rails.logger.error "[PostProcessingJob] Failed for download #{download.id}: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      request.mark_for_attention!("Post-processing failed: #{e.message}")
    end
  end

  private

  def source_path_unavailable?(source_path)
    source_path.present? && !File.exist?(source_path)
  end

  def retry_source_path_later(download, request, source_path, retry_count)
    retry_limit = SettingsService.get(:post_processing_source_path_retries).to_i
    if retry_count < retry_limit
      next_retry_count = retry_count + 1
      wait_interval = SettingsService.get(:download_check_interval).to_i.seconds

      Rails.logger.warn(
        "[PostProcessingJob] Source path not visible yet: #{source_path}. " \
          "Retrying post-processing source check #{next_retry_count}/#{retry_limit} in #{wait_interval.to_i}s."
      )

      track_request_event(
        request,
        "post_processing_waiting",
        download: download,
        message: "Source path not visible yet; retrying post-processing",
        level: :warn,
        details: { source_path: source_path, retry_count: next_retry_count, retry_limit: retry_limit }
      )

      self.class.set(wait: wait_interval).perform_later(download.id, next_retry_count)
      return
    end

    raise source_path_not_found_message(source_path)
  end

  def cleanup_usenet_download(download)
    return unless SettingsService.get(:remove_completed_usenet_downloads, default: true)
    return unless download.download_client&.usenet_client?
    return unless download.external_id.present?

    Rails.logger.info "[PostProcessingJob] Removing usenet download #{download.external_id} from #{download.download_client.name}"
    download.download_client.adapter.remove_torrent(download.external_id, delete_files: true)
    Rails.logger.info "[PostProcessingJob] Usenet download removed successfully"
  rescue => e
    Rails.logger.warn "[PostProcessingJob] Failed to remove usenet download (non-fatal): #{e.message}"
  end

  def build_destination_path(book, download)
    base_path = get_base_path(book)
    PathTemplateService.build_destination(book, base_path: base_path)
  end

  def get_base_path(book)
    # Always use Shelfarr's configured output paths.
    # Audiobookshelf library paths are from ABS's container perspective,
    # not ours, so we can't use them for file operations.
    if book.ebook?
      SettingsService.get(:ebook_output_path, default: "/ebooks")
    else
      SettingsService.get(:audiobook_output_path, default: "/audiobooks")
    end
  end

  def library_id_for(book)
    if book.audiobook?
      SettingsService.get(:audiobookshelf_audiobook_library_id)
    else
      SettingsService.get(:audiobookshelf_ebook_library_id)
    end
  end

  def copy_files(source, destination, book: nil)
    unless source.present?
      Rails.logger.error "[PostProcessingJob] Source path is blank - download client may not have reported the path"
      raise "Source path is blank. Check download client configuration and ensure the download completed successfully."
    end

    unless File.exist?(source)
      Rails.logger.error "[PostProcessingJob] Source path does not exist: #{source}"
      Rails.logger.error "[PostProcessingJob] Check path remapping settings:"
      Rails.logger.error "[PostProcessingJob]   - download_remote_path: #{SettingsService.get(:download_remote_path).inspect}"
      Rails.logger.error "[PostProcessingJob]   - download_local_path: #{SettingsService.get(:download_local_path).inspect}"
      raise source_path_not_found_message(source)
    end

    Rails.logger.info "[PostProcessingJob] Copying from #{source} to #{destination}"
    validate_ebook_source!(source) if book&.ebook?
    FileUtils.mkdir_p(destination)

    if File.directory?(source)
      # Copy all files from source directory to destination
      # Use Dir.entries instead of Dir.glob to avoid pattern matching issues
      # (e.g., [AUDIOBOOK] in path being treated as character class)
      # Files are COPIED (not moved) to preserve seeding on private trackers
      files = Dir.entries(source).reject { |f| f.start_with?(".") }
      Rails.logger.info "[PostProcessingJob] Found #{files.size} files/folders to copy"
      files.each do |file|
        source_file = File.join(source, file)

        if book&.ebook?
          copy_ebook_directory_entry(source_file, destination, book)
        else
          FileCopyService.cp_r(source_file, destination)
        end
      end
    else
      # Copy single file with renamed filename based on template
      copy_renamed_file(source, destination, book)
    end

    Rails.logger.info "[PostProcessingJob] Copy completed successfully"
  end

  def copy_ebook_directory_entry(source_file, destination, book)
    if File.directory?(source_file)
      Dir.entries(source_file).reject { |f| f.start_with?(".") }.each do |file|
        copy_ebook_directory_entry(File.join(source_file, file), destination, book)
      end
    elsif ebook_file?(source_file)
      copy_renamed_file(source_file, destination, book)
    else
      copy_sidecar_file(source_file, destination)
    end
  end

  def validate_ebook_source!(source)
    paths = if File.directory?(source)
      ebook_directory_files(source)
    else
      [ source ]
    end

    paths.each do |path|
      next if allowed_ebook_import_file?(path)

      raise "Unsupported ebook import file type: #{File.basename(path)}"
    end
  end

  def ebook_directory_files(source)
    Dir.entries(source).reject { |f| f.start_with?(".") }.flat_map do |file|
      path = File.join(source, file)
      File.directory?(path) && !File.symlink?(path) ? ebook_directory_files(path) : path
    end
  end

  def allowed_ebook_import_file?(path)
    return false if File.symlink?(path)
    return false unless File.file?(path)

    extension = File.extname(path).delete_prefix(".").downcase
    EBOOK_ALLOWED_EXTENSIONS.include?(extension) && valid_ebook_import_content?(path, extension)
  end

  def valid_ebook_import_content?(path, extension)
    file_size = File.size(path)
    return false if file_size.zero?

    head = File.binread(path, [ 512, file_size ].min)
    return false if executable_file_signature?(head)

    case extension
    when "epub", "cbz"
      head.start_with?("PK\x03\x04")
    when "pdf"
      head.start_with?("%PDF")
    when "mobi", "azw", "azw3"
      head.byteslice(60, 8) == "BOOKMOBI" || head.include?("BOOKMOBI")
    when "cbr"
      head.start_with?("Rar!\x1A\x07\x00") || head.start_with?("Rar!\x1A\x07\x01\x00")
    when "djvu"
      head.start_with?("AT&TFORM") && %w[DJVU DJVM].include?(head.byteslice(12, 4))
    when "jpg", "jpeg"
      head.start_with?("\xFF\xD8\xFF".b)
    when "png"
      head.start_with?("\x89PNG\r\n\x1A\n".b)
    when "webp"
      head.start_with?("RIFF") && head.byteslice(8, 4) == "WEBP"
    when "opf"
      text_file_content?(head) && head.downcase.include?("<package")
    when "nfo", "txt"
      text_file_content?(head)
    else
      false
    end
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def executable_file_signature?(head)
    head.start_with?("MZ") ||
      head.start_with?("\x7FELF".b) ||
      head.start_with?("\xFE\xED\xFA\xCE".b) ||
      head.start_with?("\xFE\xED\xFA\xCF".b) ||
      head.start_with?("\xCE\xFA\xED\xFE".b) ||
      head.start_with?("\xCF\xFA\xED\xFE".b)
  end

  def text_file_content?(head)
    return false if head.include?("\x00")

    head.bytes.all? do |byte|
      byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte >= 32
    end
  end

  def copy_sidecar_file(source_file, destination)
    destination_file = File.join(destination, File.basename(source_file))
    destination_file = handle_duplicate_filename(destination_file) if File.exist?(destination_file)
    FileCopyService.cp(source_file, destination_file)
  end

  def copy_renamed_file(source, destination, book)
    destination_file = renamed_destination_file(source, destination, book)
    Rails.logger.info "[PostProcessingJob] Renaming file to: #{File.basename(destination_file)}"
    FileCopyService.cp(source, destination_file)
  end

  def renamed_destination_file(source, destination, book)
    extension = File.extname(source)
    new_filename = book ? PathTemplateService.build_filename(book, extension) : File.basename(source)
    destination_file = File.join(destination, new_filename)

    destination_file = handle_duplicate_filename(destination_file) if File.exist?(destination_file)
    destination_file
  end

  def ebook_file?(path)
    EBOOK_FILE_EXTENSIONS.include?(File.extname(path).delete_prefix(".").downcase)
  end

  def handle_duplicate_filename(path)
    dir = File.dirname(path)
    ext = File.extname(path)
    base = File.basename(path, ext)

    counter = 1
    new_path = path
    while File.exist?(new_path)
      counter += 1
      new_path = File.join(dir, "#{base} (#{counter})#{ext}")
    end
    new_path
  end

  # Remap paths from download client (host) to container paths.
  # Builds a list of candidate paths and returns the first one that exists on disk.
  # This handles different client configurations (with/without category, with/without
  # per-client download_path) without requiring a single "correct" configuration.
  def remap_download_path(path, download)
    if path.blank?
      Rails.logger.warn "[PostProcessingJob] Download path is blank - download client didn't report a path"
      return path
    end

    Rails.logger.info "[PostProcessingJob] Path remapping - original path from client: #{path}"

    candidates = build_path_candidates(path, download)
    candidates = deduplicate_path_candidates(candidates)

    # Return the first candidate that actually exists on disk.
    candidates.each do |candidate|
      next if candidate[:path].blank?

      if File.exist?(candidate[:path])
        Rails.logger.info "[PostProcessingJob] Path resolved via #{candidate[:strategy]}: #{candidate[:path]}"
        return candidate[:path]
      end
    end

    # None found - log all candidates for debugging
    Rails.logger.warn "[PostProcessingJob] No remapped path exists on disk. Candidates tried:"
    candidates.each { |c| Rails.logger.warn "[PostProcessingJob]   #{c[:strategy]}: #{c[:path]}" }

    # Return the first non-nil candidate so copy_files produces a clear "not found" error
    best_guess = candidates.find { |c| c[:path].present? }
    best_guess ? best_guess[:path] : path
  end

  def build_path_candidates(path, download)
    candidates = []
    normalized_path = normalize_path_separators(path)
    remote_path = normalize_path_separators(SettingsService.get(:download_remote_path))
    local_path = normalize_path_separators(SettingsService.get(:download_local_path, default: "/downloads"))
    category = download.download_client&.category
    client_download_path = normalize_path_separators(download.download_client&.download_path)
    basename = File.basename(normalized_path)

    # 1. Global remote_path → local_path prefix replacement
    if remote_path.present? && path_prefix_match?(normalized_path, remote_path)
      candidates << { strategy: "global_prefix_remap", path: replace_path_prefix(normalized_path, remote_path, local_path) }
    end

    # 2. local_path/category/basename — most common torrent client layout
    if category.present?
      candidates << { strategy: "local_path_with_category", path: File.join(local_path, category, basename) }
    end

    # 3. Category-aware sibling remap — when remote_path points to a sibling folder
    #    e.g., remote=/mnt/Torrents/Completed, path=/mnt/Torrents/shelfarr/File
    if category.present? && remote_path.present? && normalized_path.include?("/#{category}/")
      category_idx = normalized_path.index("/#{category}/")
      remote_base = normalized_path[0...category_idx]
      relative_after_base = normalized_path[(category_idx)..]

      if remote_base == File.dirname(remote_path)
        candidates << { strategy: "category_sibling_remap", path: File.join(File.dirname(local_path), relative_after_base) }
      end
    end

    # 4. Client download_path + basename
    if client_download_path.present?
      candidates << { strategy: "client_download_path", path: File.join(client_download_path, basename) }
    end

    # 5. local_path/basename (no category)
    candidates << { strategy: "local_path_basename", path: File.join(local_path, basename) }

    # 6. Original path as-is (works when download client runs in the same filesystem)
    candidates << { strategy: "original_path", path: path }

    candidates
  end

  def normalize_path_separators(path)
    path.to_s.tr("\\", "/") if path.present?
  end

  def path_prefix_match?(path, prefix)
    return false unless path.start_with?(prefix)

    path.length == prefix.length || prefix.end_with?("/") || path[prefix.length] == "/"
  end

  def replace_path_prefix(path, remote_path, local_path)
    suffix = path.delete_prefix(remote_path).sub(%r{\A/+}, "")
    suffix.present? ? File.join(local_path, suffix) : local_path
  end

  def deduplicate_path_candidates(candidates)
    seen = {}

    candidates.select do |candidate|
      path = candidate[:path]
      next true if path.blank?
      next false if seen.key?(path)

      seen[path] = true
      true
    end
  end

  def source_path_not_found_message(source)
    "Source path not found: #{source}. Verify path remapping settings " \
      "(download_remote_path/download_local_path) match your container mount points."
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

  def sanitize_filename(name)
    # Remove invalid filename characters, collapse whitespace
    name
      .gsub(/[<>:"\/\\|?*]/, "")  # Remove invalid chars
      .gsub(/[\x00-\x1f]/, "")    # Remove control characters
      .strip
      .gsub(/\s+/, " ")           # Collapse whitespace
      .truncate(100, omission: "") # Limit length
  end

  def pre_create_download_zip(book, path)
    require "zip"

    zip_filename = "#{book.author} - #{book.title}.zip".gsub(/[\/\\:*?"<>|]/, "_")
    safe_filename = zip_filename.gsub(/\s+/, "_")

    downloads_dir = Rails.root.join("tmp", "downloads")
    FileUtils.mkdir_p(downloads_dir)
    zip_path = downloads_dir.join("book_#{book.id}_#{safe_filename}")

    Rails.logger.info "[PostProcessingJob] Pre-creating download zip: #{zip_path}"

    Zip::File.open(zip_path.to_s, create: true) do |zipfile|
      Dir.entries(path).reject { |f| f.start_with?(".") }.each do |file|
        full_path = File.join(path, file)
        next if File.directory?(full_path)
        zipfile.add(file, full_path)
      end
    end

    Rails.logger.info "[PostProcessingJob] Download zip ready: #{(File.size(zip_path) / 1024.0 / 1024.0).round(2)} MB"
  rescue => e
    Rails.logger.warn "[PostProcessingJob] Failed to pre-create zip (non-fatal): #{e.message}"
    # Non-fatal - zip will be created on first download
  end

  def trigger_library_scan(book)
    lib_id = library_id_for(book)
    return unless lib_id.present?

    AudiobookshelfClient.scan_library(lib_id)
    Rails.logger.info "[PostProcessingJob] Triggered Audiobookshelf library scan for #{book.book_type}"
  rescue AudiobookshelfClient::Error => e
    Rails.logger.warn "[PostProcessingJob] Failed to trigger scan: #{e.message}"
    # Non-fatal - Audiobookshelf will pick up files on next auto-scan
  end
end
