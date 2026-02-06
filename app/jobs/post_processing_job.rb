# frozen_string_literal: true

# Copies completed downloads to library folder and triggers library scan.
# Files are COPIED (not moved) to preserve seeding on private trackers.
class PostProcessingJob < ApplicationJob
  queue_as :default

  def perform(download_id)
    download = Download.find_by(id: download_id)
    return unless download&.completed?

    request = download.request
    book = request.book

    Rails.logger.info "[PostProcessingJob] Starting post-processing for download #{download.id} (#{book.title})"

    request.update!(status: :processing)

    begin
      destination = build_destination_path(book, download)
      source_path = remap_download_path(download.download_path, download)
      copy_files(source_path, destination, book: book)

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
      NotificationService.request_attention(request)
    end
  end

  private

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
      raise "Source path not found: #{source}. Verify path remapping settings (download_remote_path/download_local_path) match your container mount points."
    end

    Rails.logger.info "[PostProcessingJob] Copying from #{source} to #{destination}"
    FileUtils.mkdir_p(destination)

    if File.directory?(source)
      # Copy all files from source directory to destination
      # Use Dir.entries instead of Dir.glob to avoid pattern matching issues
      # (e.g., [AUDIOBOOK] in path being treated as character class)
      # Files are COPIED (not moved) to preserve seeding on private trackers
      files = Dir.entries(source).reject { |f| f.start_with?(".") }
      Rails.logger.info "[PostProcessingJob] Found #{files.size} files/folders to copy"
      files.each do |file|
        FileCopyService.cp_r(File.join(source, file), destination)
      end
    else
      # Copy single file with renamed filename based on template
      extension = File.extname(source)
      new_filename = book ? PathTemplateService.build_filename(book, extension) : File.basename(source)
      destination_file = File.join(destination, new_filename)

      # Handle duplicate filenames
      destination_file = handle_duplicate_filename(destination_file) if File.exist?(destination_file)

      Rails.logger.info "[PostProcessingJob] Renaming file to: #{new_filename}"
      FileCopyService.cp(source, destination_file)
    end

    Rails.logger.info "[PostProcessingJob] Copy completed successfully"
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

  # Remap paths from download client (host) to container paths
  # Download clients report paths from their perspective (e.g., /mnt/media/Torrents/Completed/...)
  # But Shelfarr's container may have those files mounted at a different path (e.g., /downloads/...)
  def remap_download_path(path, download)
    if path.blank?
      Rails.logger.warn "[PostProcessingJob] Download path is blank - download client didn't report a path"
      return path
    end

    Rails.logger.info "[PostProcessingJob] Path remapping - original path from download client: #{path}"

    # Try global settings first - these do proper prefix replacement
    # which preserves the full path structure (including category subfolders)
    remote_path = SettingsService.get(:download_remote_path)
    local_path = SettingsService.get(:download_local_path, default: "/downloads")

    if remote_path.present? && path.start_with?(remote_path)
      remapped = path.sub(remote_path, local_path)
      Rails.logger.info "[PostProcessingJob] Path remapped via global settings: #{remapped}"
      return remapped
    elsif remote_path.present?
      Rails.logger.warn "[PostProcessingJob] Global remote_path is set (#{remote_path}) but doesn't match download path (#{path})"
    end

    # Fall back to client-specific download path
    # This is a simpler mapping that uses the basename (filename or folder name)
    # Use this when global settings aren't configured or don't match
    if download.download_client&.download_path.present?
      client_path = download.download_client.download_path
      basename = File.basename(path)
      remapped = File.join(client_path, basename)
      Rails.logger.info "[PostProcessingJob] Path remapped via client download_path: #{remapped}"
      return remapped
    end

    # No remapping configured - use path as-is
    Rails.logger.warn "[PostProcessingJob] No path remapping configured - using original path as-is"
    Rails.logger.warn "[PostProcessingJob] Consider configuring download_remote_path/download_local_path in Settings if files are not found"
    path
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
