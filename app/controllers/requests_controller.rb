# frozen_string_literal: true

class RequestsController < ApplicationController
  before_action :set_request, only: [ :show, :destroy, :download ]
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def index
    @requests = if Current.user.admin?
      Request.includes(:book, :user).order(created_at: :desc)
    else
      Request.for_user(Current.user).includes(:book).order(created_at: :desc)
    end
  end

  def show
  end

  def new
    @work_id = params[:work_id]
    @title = params[:title]
    @author = params[:author]
    @cover_id = params[:cover_id]
    @first_publish_year = params[:first_publish_year]

    if @work_id.blank? || @title.blank?
      redirect_to search_path, alert: "Missing book information"
      return
    end

    @default_language = SettingsService.get(:default_language)
    @enabled_languages = enabled_language_options
  end

  def create
    work_id = params[:work_id]
    # Support both single book_type (legacy) and multiple book_types[]
    book_types = params[:book_types].presence || [ params[:book_type] ].compact

    if work_id.blank? || book_types.empty?
      redirect_to search_path, alert: "Missing required information"
      return
    end

    created_requests = []
    warnings = []
    errors = []

    book_types.each do |book_type|
      # Check for duplicates
      duplicate_check = DuplicateDetectionService.check(
        work_id: work_id,
        book_type: book_type
      )

      if duplicate_check.block?
        errors << "#{book_type.titleize}: #{duplicate_check.message}"
        next
      end

      warnings << duplicate_check.message if duplicate_check.warn?

      # Find or create the book
      book = Book.find_or_initialize_by(
        open_library_work_id: work_id,
        book_type: book_type
      )

      if book.new_record?
        book.assign_attributes(
          title: params[:title],
          author: params[:author],
          cover_url: params[:cover_id].present? ? OpenLibraryClient.cover_url(params[:cover_id], size: :l) : nil,
          year: params[:first_publish_year]
        )
        book.save!
      end

      request = Current.user.requests.build(book: book, status: :pending)
      request.notes = params[:notes] if params[:notes].present?
      request.language = params[:language] if params[:language].present?

      if request.save
        ActivityTracker.track("request.created", trackable: request)
        created_requests << request
      else
        errors << "#{book_type.titleize}: #{request.errors.full_messages.join(', ')}"
      end
    end

    if created_requests.empty?
      redirect_to search_path, alert: errors.join(". ")
    elsif created_requests.length == 1
      flash_message = "Request created for #{created_requests.first.book.display_name}"
      flash_message += " (#{warnings.join(', ')})" if warnings.any?
      redirect_to created_requests.first, notice: flash_message
    else
      flash_message = "#{created_requests.length} requests created for #{created_requests.first.book.title}"
      flash_message += " (#{warnings.join(', ')})" if warnings.any?
      redirect_to requests_path, notice: flash_message
    end
  end

  def destroy
    unless @request.user == Current.user || Current.user.admin?
      redirect_to requests_path, alert: "You cannot cancel this request"
      return
    end

    unless @request.pending? || @request.not_found? || @request.failed?
      redirect_to @request, alert: "Cannot cancel request in #{@request.status} status"
      return
    end

    book = @request.book
    ActivityTracker.track("request.cancelled", trackable: @request)
    @request.destroy!

    # Clean up orphaned books with no requests and no file
    if book.requests.empty? && !book.acquired?
      book.destroy
    end

    redirect_to requests_path, notice: "Request cancelled"
  end

  def download
    book = @request.book

    unless book.acquired? && book.file_path.present?
      redirect_to @request, alert: "This book is not available for download"
      return
    end

    path = book.file_path

    # Security: Validate path is within allowed directories
    unless path_within_allowed_directories?(path)
      Rails.logger.warn "[Security] Attempted path traversal: #{path}"
      redirect_to @request, alert: "Invalid file path"
      return
    end

    unless File.exist?(path)
      redirect_to @request, alert: "File not found on server"
      return
    end

    if File.directory?(path)
      send_zipped_directory(path, book)
    else
      send_single_file(path, book)
    end
  end

  private

  def send_single_file(path, book)
    filename = File.basename(path)
    content_type = Marcel::MimeType.for(name: filename) || "application/octet-stream"

    send_file path,
              filename: filename,
              type: content_type,
              disposition: "attachment"
  end

  def send_zipped_directory(path, book)
    zip_filename = "#{book.author} - #{book.title}.zip".gsub(/[\/\\:*?"<>|]/, "_")
    safe_filename = zip_filename.gsub(/\s+/, "_")

    # Use a stable path based on book ID so we can cache the zip
    downloads_dir = Rails.root.join("tmp", "downloads")
    FileUtils.mkdir_p(downloads_dir)
    cached_zip_path = downloads_dir.join("book_#{book.id}_#{safe_filename}")

    # Check if cached zip exists and is newer than source directory
    source_mtime = Dir.glob("#{path}/*").map { |f| File.mtime(f) }.max
    if File.exist?(cached_zip_path) && File.mtime(cached_zip_path) >= source_mtime
      Rails.logger.info "[Download] Serving cached zip: #{cached_zip_path}"
    else
      Rails.logger.info "[Download] Creating zip for #{book.title} (this may take a while for large files)..."
      create_zip_file(path, cached_zip_path.to_s)
      Rails.logger.info "[Download] Zip created: #{cached_zip_path}"
    end

    send_file cached_zip_path,
              filename: zip_filename,
              type: "application/zip",
              disposition: "attachment"
  rescue => e
    Rails.logger.error "[Download] Error creating zip: #{e.message}"
    raise
  end

  def create_zip_file(source_dir, zip_path)
    require "zip"

    # Delete existing zip to avoid "Entry already exists" errors
    File.delete(zip_path) if File.exist?(zip_path)

    source_dir_real = File.realpath(source_dir)

    Zip::File.open(zip_path, create: true) do |zipfile|
      Dir[File.join(source_dir, "**", "*")].each do |file|
        next if File.directory?(file)
        next if File.symlink?(file) # Skip symlinks for security

        # Verify file is within source directory (prevent symlink attacks)
        file_real = File.realpath(file) rescue next
        next unless file_real.start_with?(source_dir_real)

        relative_path = file.sub("#{source_dir}/", "")
        zipfile.add(relative_path, file)
      end
    end
  end

  def path_within_allowed_directories?(path)
    return false if path.blank?

    # Resolve to absolute path
    expanded_path = File.expand_path(path)

    # Get allowed base directories from settings
    allowed_paths = [
      SettingsService.get(:audiobook_output_path),
      SettingsService.get(:ebook_output_path)
    ].compact.reject(&:blank?)

    # Check if path is within any allowed directory
    allowed_paths.any? do |allowed|
      expanded_allowed = File.expand_path(allowed)
      expanded_path.start_with?(expanded_allowed + "/") || expanded_path == expanded_allowed
    end
  end

  def set_request
    @request = if Current.user.admin?
      Request.find(params[:id])
    else
      Request.for_user(Current.user).find(params[:id])
    end
  end

  def record_not_found
    head :not_found
  end

  def enabled_language_options
    enabled_codes = SettingsService.get(:enabled_languages) || [ "en" ]
    # Setting model's typed_value getter handles JSON parsing and error recovery
    enabled_codes = Array(enabled_codes) # Ensure it's an array

    enabled_codes.filter_map do |code|
      info = ReleaseParserService.language_info(code)
      next unless info

      [ info[:name], code ]
    end.sort_by(&:first)
  end
end
