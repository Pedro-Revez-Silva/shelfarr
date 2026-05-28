# frozen_string_literal: true

require "fileutils"

class WatchDirectoryJob < ApplicationJob
  queue_as :default

  def perform
    interval = SettingsService.get(:watch_directory_interval).to_i
    if interval <= 0
      Rails.logger.info "[WatchDirectoryJob] Watch directory monitoring is disabled (interval set to #{interval})"
      return
    end

    # Check if enough time has passed since the last run
    last_run_setting = Setting.find_by(key: "watch_directory_last_run_at")
    last_run_at = last_run_setting ? Time.zone.parse(last_run_setting.value) : nil
    if last_run_at && (Time.current - last_run_at) < (interval * 60 - 5) # 5s buffer
      return
    end

    watch_dir = SettingsService.get(:watch_directory_path) || "/watch"
    return unless Dir.exist?(watch_dir)

    admin_user = User.where(role: :admin).first
    unless admin_user
      Rails.logger.error "[WatchDirectoryJob] No admin user found to attribute uploads to"
      return
    end

    process_directory(watch_dir, admin_user)

    # Record the last run time
    if last_run_setting
      last_run_setting.update!(value: Time.current.to_s)
    else
      Setting.create!(
        key: "watch_directory_last_run_at",
        value: Time.current.to_s,
        value_type: "string",
        category: "internal",
        description: "Internal: Last time the watch directory was scanned"
      )
    end
  end

  private

  def process_directory(dir, user)
    # Find all supported files in this directory and subdirectories
    all_files = Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) }
    
    # Group files by their parent directory to check for multi-file audiobooks
    files_by_dir = all_files.group_by { |f| File.dirname(f) }

    files_by_dir.each do |parent_dir, files|
      # Check if this directory contains multiple audio files
      audio_files = files.select { |f| Upload::AUDIOBOOK_EXTENSIONS.include?(File.extname(f).delete(".").downcase) }
      
      if audio_files.size > 1
        Rails.logger.info "[WatchDirectoryJob] Skipping directory with multiple audio files: #{parent_dir}"
        next
      end

      # Process supported files in this directory
      files.each do |file_path|
        extension = File.extname(file_path).delete(".").downcase
        next unless Upload::SUPPORTED_EXTENSIONS.include?(extension)

        process_file(file_path, user)
      end
    end
  end

  def process_file(file_path, user)
    # Check if we've already processed this file
    return if Upload.exists?(watch_dir_path: file_path)

    Rails.logger.info "[WatchDirectoryJob] Processing new file from watch directory: #{file_path}"

    temp_path = copy_to_temp(file_path)
    return unless temp_path

    upload = Upload.new(
      user: user,
      original_filename: File.basename(file_path),
      file_path: temp_path,
      file_size: File.size(file_path),
      content_type: content_type_for(file_path),
      status: :pending,
      watch_dir_path: file_path
    )

    if upload.save
      UploadProcessingJob.perform_later(upload.id)
    else
      Rails.logger.error "[WatchDirectoryJob] Failed to create upload for #{file_path}: #{upload.errors.full_messages.join(', ')}"
      FileUtils.rm_f(temp_path)
    end
  end

  def copy_to_temp(file_path)
    upload_dir = Rails.root.join("tmp", "uploads")
    FileUtils.mkdir_p(upload_dir)

    timestamp = Time.current.strftime("%Y%m%d%H%M%S")
    random = SecureRandom.hex(4)
    extension = File.extname(file_path)
    filename = "#{timestamp}_#{random}#{extension}"
    dest_path = upload_dir.join(filename)

    FileUtils.cp(file_path, dest_path)
    dest_path.to_s
  rescue => e
    Rails.logger.error "[WatchDirectoryJob] Failed to copy #{file_path} to temp: #{e.message}"
    nil
  end

  def content_type_for(file_path)
    extension = File.extname(file_path).delete(".").downcase
    case extension
    when "mp3" then "audio/mpeg"
    when "m4a", "m4b" then "audio/mp4"
    when "epub" then "application/epub+zip"
    when "pdf" then "application/pdf"
    when "zip" then "application/zip"
    when "rar" then "application/x-rar-compressed"
    else "application/octet-stream"
    end
  end
end
