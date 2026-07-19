# frozen_string_literal: true

require "find"

# Cleans up temporary files:
# - ZIP downloads older than 1 hour
# - Orphaned upload files older than 24 hours
class CleanupTempFilesJob < ApplicationJob
  queue_as :default

  ARCHIVE_CACHE_PATTERN = /\Abook_(\d+)_v\d+_[0-9a-f]{64}\.zip\z/
  ARCHIVE_STAGING_PATTERN = /\A\.book_(\d+)_archive-[0-9a-f]{32}\.zip\z/
  ARCHIVE_LOCK_PATTERN = /\A\.archive-lock-[0-9a-f]{2}\z/
  ARCHIVE_ADMISSION_PATTERN = /\A\.archive-build-slot-[0-9a-f]{2}\z/

  def perform
    cleanup_download_temps
    cleanup_upload_temps
    cleanup_old_activity_logs
    cleanup_old_request_events
  end

  private

  def cleanup_download_temps
    downloads_dir = Rails.root.join("tmp", "downloads")
    return unless File.lstat(downloads_dir).directory?

    FileCopyService.directory_identity(downloads_dir, root: Rails.root.join("tmp"))

    deleted_count = cleanup_download_directory(downloads_dir, max_age: 1.hour.ago)

    Rails.logger.info "[CleanupTempFilesJob] Deleted #{deleted_count} old download temp files" if deleted_count > 0
  rescue Errno::ENOENT
    nil
  rescue FileCopyService::UnsafePathError, SystemCallError => error
    Rails.logger.warn "[CleanupTempFilesJob] Could not safely inspect download archives: #{error.class}"
  end

  def cleanup_download_directory(downloads_dir, max_age:)
    downloads_dir = Pathname(downloads_dir).expand_path
    entries = Dir.each_child(downloads_dir).to_a
    deleted = entries.sum do |entry|
      next 0 unless entry.valid_encoding?

      match = ARCHIVE_CACHE_PATTERN.match(entry) || ARCHIVE_STAGING_PATTERN.match(entry)
      if match
        cleanup_coordinated_archive_entry(
          downloads_dir,
          entry,
          book_id: match[1],
          max_age: max_age
        )
      elsif ARCHIVE_LOCK_PATTERN.match?(entry) || ARCHIVE_ADMISSION_PATTERN.match?(entry)
        0
      else
        cleanup_legacy_download_entry(downloads_dir, entry, max_age: max_age)
      end
    end

    deleted
  rescue Errno::ENOENT
    0
  end

  def cleanup_coordinated_archive_entry(downloads_dir, entry, book_id:, max_age:)
    path = downloads_dir.join(entry)
    lock_path = LibraryDownloadArchiveService.lock_path_for_book(
      book_id,
      directory: downloads_dir
    )
    removed = false
    FileCopyService.with_private_lock(lock_path, root: downloads_dir.to_s) do
      stale = FileCopyService.with_regular_file(path, root: downloads_dir.to_s) do |file|
        file.stat.mtime <= max_age
      end
      removed = FileCopyService.remove_regular_file_safely(path, root: downloads_dir.to_s) if stale
    end
    removed ? 1 : 0
  rescue Errno::ENOENT
    0
  rescue FileCopyService::UnsafePathError, FileCopyService::AtomicPublicationUnsupportedError,
    SystemCallError => error
    Rails.logger.warn "[CleanupTempFilesJob] Could not safely clean a download archive: #{error.class}"
    0
  end

  def cleanup_legacy_download_entry(downloads_dir, entry, max_age:)
    path = downloads_dir.join(entry)
    stat = File.lstat(path)
    return 0 unless stat.file? && stat.mtime <= max_age

    FileCopyService.remove_regular_file_safely(path, root: downloads_dir.to_s) ? 1 : 0
  rescue Errno::ENOENT
    0
  rescue FileCopyService::UnsafePathError, FileCopyService::AtomicPublicationUnsupportedError,
    SystemCallError => error
    Rails.logger.warn "[CleanupTempFilesJob] Could not safely clean a legacy download file: #{error.class}"
    0
  end

  def cleanup_upload_temps
    max_age = 24.hours.ago
    protected_paths = Upload.pending_or_processing.pluck(:file_path).compact.to_set
    protected_paths.merge(
      Upload.where.not(cleanup_source_path: nil).pluck(:cleanup_source_path).compact
    )
    directories = [ Rails.root.join("tmp", "uploads") ]
    owned_staging_roots.each do |root|
      # Each Shelfarr database owns only its fingerprinted subdirectory. Two
      # instances may intentionally share one audiobook filesystem and must
      # never sweep one another's durable uploads.
      directories << OwnedMediaImportFileService.staging_upload_directory(root: root)
    end

    deleted_count = directories.uniq.sum do |directory|
      cleanup_upload_directory(directory, max_age: max_age, protected_paths: protected_paths)
    end

    Rails.logger.info "[CleanupTempFilesJob] Deleted #{deleted_count} orphaned upload files" if deleted_count > 0
  rescue Errno::ENOENT, Errno::EACCES => e
    Rails.logger.warn "[CleanupTempFilesJob] Could not inspect upload staging: #{e.class}"
  end

  def owned_staging_roots
    configured = Pathname(
      SettingsService.get(:audiobook_output_path, default: "/audiobooks").to_s.presence ||
        "/audiobooks"
    ).expand_path
    roots = []
    roots << configured.realpath if configured.directory?

    # A user can change audiobook_output_path while completed/failed imports
    # still reference the previous durable staging volume. Derive every valid
    # historical root from persisted owned-upload paths so those orphan files
    # remain eligible for cleanup instead of leaking indefinitely.
    OwnedMediaImport.joins(:upload).pluck("uploads.file_path").compact.each do |path|
      roots << OwnedMediaImportFileService.output_root_for_staged_path(path)
    rescue OwnedMediaImportFileService::Error
      next
    end
    roots.uniq
  rescue Errno::ENOENT, Errno::EACCES
    roots || []
  end

  def cleanup_upload_directory(directory, max_age:, protected_paths:)
    return 0 unless File.directory?(directory)

    directory = Pathname(directory).expand_path
    protected_directories = protected_paths.each_with_object(Set.new) do |raw_path, paths|
      path = Pathname(raw_path).expand_path
      next unless path.to_s.start_with?("#{directory}#{File::SEPARATOR}")

      parent = path.parent
      while parent != directory && parent.to_s.start_with?("#{directory}#{File::SEPARATOR}")
        paths << parent.to_s
        parent = parent.parent
      end
    end
    deleted_count = 0
    child_directories = []
    Find.find(directory.to_s) do |entry|
      next if entry == directory.to_s

      stat = File.lstat(entry)
      if stat.directory?
        child_directories << entry
        next
      end
      next if stat.mtime > max_age
      next if protected_paths.include?(entry)

      deleted_count += 1 if delete_upload_file_unless_active(entry, max_age: max_age)
    rescue Errno::ENOENT
      next
    end

    child_directories.reverse_each do |child|
      next if protected_directories.include?(child)

      Dir.rmdir(child) if Dir.empty?(child)
    rescue Errno::ENOENT, Errno::ENOTEMPTY
      next
    end
    deleted_count
  end

  def delete_upload_file_unless_active(path, max_age:)
    # Referenced files are not orphans. Preserve every Upload status so failed
    # Audible backups remain retryable and a failed->pending transition cannot
    # race cleanup on SQLite (where SELECT ... FOR UPDATE is not a row lock).
    return false if Upload.where(file_path: path).exists?

    stat = File.lstat(path)
    return false unless stat.file? && stat.mtime <= max_age

    File.unlink(path)
    true
  rescue Errno::ENOENT
    false
  end

  def cleanup_old_activity_logs
    # Keep 90 days of logs
    deleted_count = ActivityLog.where("created_at < ?", 90.days.ago).delete_all
    Rails.logger.info "[CleanupTempFilesJob] Deleted #{deleted_count} old activity logs" if deleted_count > 0
  end

  def cleanup_old_request_events
    # Keep 90 days of request diagnostics
    deleted_count = RequestEvent.where("created_at < ?", 90.days.ago).delete_all
    Rails.logger.info "[CleanupTempFilesJob] Deleted #{deleted_count} old request events" if deleted_count > 0
  end
end
