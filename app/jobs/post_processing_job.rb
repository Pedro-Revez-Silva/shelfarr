# frozen_string_literal: true

# Copies completed downloads to library folder and triggers library scan.
# Files are COPIED (not moved) to preserve seeding for torrent downloads.
# Usenet downloads are removed from the client after successful import.
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
      NotificationService.request_attention(request)
    end
  end

  private

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

    # Return the first candidate that actually exists on disk
    candidates.each do |candidate|
      next if candidate[:path].blank?

      if File.exist?(candidate[:path])
        Rails.logger.info "[PostProcessingJob] Path resolved via #{candidate[:strategy]}: #{candidate[:path]}"
        return candidate[:path]
      end
    end

    # None found — log all candidates for debugging
    Rails.logger.warn "[PostProcessingJob] No remapped path exists on disk. Candidates tried:"
    candidates.each { |c| Rails.logger.warn "[PostProcessingJob]   #{c[:strategy]}: #{c[:path]}" }

    # Return the first non-nil candidate so copy_files produces a clear "not found" error
    best_guess = candidates.find { |c| c[:path].present? }
    best_guess ? best_guess[:path] : path
  end

  def build_path_candidates(path, download)
    candidates = []
    remote_path = SettingsService.get(:download_remote_path)
    local_path = SettingsService.get(:download_local_path, default: "/downloads")
    category = download.download_client&.category
    client_download_path = download.download_client&.download_path
    basename = File.basename(path)

    # 1. Global remote_path → local_path prefix replacement
    if remote_path.present? && path.start_with?(remote_path)
      candidates << { strategy: "global_prefix_remap", path: path.sub(remote_path, local_path) }
    end

    # 2. local_path/category/basename — most common torrent client layout
    if category.present?
      candidates << { strategy: "local_path_with_category", path: File.join(local_path, category, basename) }
    end

    # 3. Category-aware sibling remap — when remote_path points to a sibling folder
    #    e.g., remote=/mnt/Torrents/Completed, path=/mnt/Torrents/shelfarr/File
    if category.present? && remote_path.present? && path.include?("/#{category}/")
      category_idx = path.index("/#{category}/")
      remote_base = path[0...category_idx]
      relative_after_base = path[(category_idx)..]

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
