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
      copy_files(source_path, destination)

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

  def copy_files(source, destination)
    return unless source.present? && File.exist?(source)

    FileUtils.mkdir_p(destination)

    if File.directory?(source)
      # Copy all files from source directory to destination
      # Use Dir.entries instead of Dir.glob to avoid pattern matching issues
      # (e.g., [AUDIOBOOK] in path being treated as character class)
      # Files are COPIED (not moved) to preserve seeding on private trackers
      Dir.entries(source).reject { |f| f.start_with?(".") }.each do |file|
        FileUtils.cp_r(File.join(source, file), destination)
      end
    else
      # Copy single file
      FileUtils.cp(source, destination)
    end
  end

  # Remap paths from download client (host) to container paths
  # SABnzbd returns host paths like /mnt/media/Torrents/Completed/...
  # Container has this mounted at /downloads/...
  def remap_download_path(path, download)
    return path if path.blank?

    # Try client-specific download path first
    if download.download_client&.download_path.present?
      # Client has a configured path - use it with the filename/dirname from the reported path
      client_path = download.download_client.download_path
      basename = File.basename(path)
      return File.join(client_path, basename)
    end

    # Fall back to global settings
    remote_path = SettingsService.get(:download_remote_path)
    local_path = SettingsService.get(:download_local_path, default: "/downloads")

    if remote_path.present? && path.start_with?(remote_path)
      path.sub(remote_path, local_path)
    else
      path
    end
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
