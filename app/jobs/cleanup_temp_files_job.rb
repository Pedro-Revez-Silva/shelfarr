# frozen_string_literal: true

# Cleans up temporary files:
# - ZIP downloads older than 1 hour
# - Orphaned upload files older than 24 hours
class CleanupTempFilesJob < ApplicationJob
  queue_as :default

  def perform
    cleanup_download_temps
    cleanup_upload_temps
    cleanup_old_activity_logs
  end

  private

  def cleanup_download_temps
    downloads_dir = Rails.root.join("tmp", "downloads")
    return unless File.directory?(downloads_dir)

    max_age = 1.hour.ago
    deleted_count = 0

    Dir.glob(downloads_dir.join("*")).each do |file|
      next if File.directory?(file)
      # Handle race condition where file is deleted between glob and mtime check
      begin
        next if File.mtime(file) > max_age
      rescue Errno::ENOENT
        next
      end

      FileUtils.rm_f(file)
      deleted_count += 1
    end

    Rails.logger.info "[CleanupTempFilesJob] Deleted #{deleted_count} old download temp files" if deleted_count > 0
  end

  def cleanup_upload_temps
    uploads_dir = Rails.root.join("tmp", "uploads")
    return unless File.directory?(uploads_dir)

    max_age = 24.hours.ago
    deleted_count = 0

    Dir.glob(uploads_dir.join("*")).each do |file|
      next if File.directory?(file)
      # Handle race condition where file is deleted between glob and mtime check
      begin
        next if File.mtime(file) > max_age
      rescue Errno::ENOENT
        next
      end
      # Don't delete files referenced by pending/processing uploads
      next if Upload.pending_or_processing.where(file_path: file).exists?

      FileUtils.rm_f(file)
      deleted_count += 1
    end

    Rails.logger.info "[CleanupTempFilesJob] Deleted #{deleted_count} orphaned upload files" if deleted_count > 0
  end

  def cleanup_old_activity_logs
    # Keep 90 days of logs
    deleted_count = ActivityLog.where("created_at < ?", 90.days.ago).delete_all
    Rails.logger.info "[CleanupTempFilesJob] Deleted #{deleted_count} old activity logs" if deleted_count > 0
  end
end
