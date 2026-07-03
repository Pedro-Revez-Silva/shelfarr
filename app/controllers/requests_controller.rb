# frozen_string_literal: true

class RequestsController < ApplicationController
  before_action :set_request, only: [ :show, :destroy, :retry, :manual_magnet ]
  before_action :set_request_for_download, only: [ :download ]
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def index
    @requests = if Current.user.admin?
      Request.includes(:book, :user, :search_results)
    else
      Request.for_user(Current.user).includes(:book, :search_results)
    end

    # Apply status filter
    if params[:status].present?
      case params[:status]
      when "active"
        # Active tab shows active requests that DON'T need attention
        @requests = @requests.active.where(attention_needed: false)
      else
        @requests = @requests.where(status: params[:status])
      end
    end

    # Apply attention filter
    @requests = @requests.needs_attention if params[:attention] == "true"

    @requests = @requests.order(created_at: :desc)

    # Counts for filter tabs
    base_requests = Current.user.admin? ? Request : Request.for_user(Current.user)
    @attention_count = base_requests.needs_attention.count
    @active_count = base_requests.active.where(attention_needed: false).count
  end

  def show
    @request_events = Current.user.admin? ? @request.request_events.recent.limit(10) : RequestEvent.none
  end

  def new
    @work_id = params[:work_id]
    @title = params[:title]
    @author = params[:author]
    @cover_url = params[:cover_url]
    @first_publish_year = params[:first_publish_year]
    @source_work_ids = Array(params[:source_work_ids]).compact_blank

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

    result = RequestCreationService.call(
      user: Current.user,
      work_id: work_id,
      book_types: book_types,
      metadata_attrs: request_metadata_attrs,
      notes: params[:notes],
      language: params[:language],
      source_work_ids: params[:source_work_ids]
    )

    if result.created_requests.empty?
      redirect_to search_path, alert: result.errors.join(". ")
    elsif result.created_requests.length == 1
      flash_message = "Request created for #{result.created_requests.first.book.display_name}"
      flash_message += " (#{result.warnings.join(', ')})" if result.warnings.any?
      redirect_to result.created_requests.first, notice: flash_message
    else
      flash_message = "#{result.created_requests.length} requests created for #{result.created_requests.first.book.title}"
      flash_message += " (#{result.warnings.join(', ')})" if result.warnings.any?
      redirect_to requests_path, notice: flash_message
    end
  end

  def destroy
    unless @request.user == Current.user || Current.user.admin?
      redirect_to requests_path, alert: "You cannot cancel this request"
      return
    end

    unless @request.can_be_cancelled?
      redirect_to @request, alert: "Cannot cancel request in #{@request.status} status"
      return
    end

    # Optionally remove torrent from download client
    if params[:remove_torrent] == "1"
      remove_associated_torrents(@request)
    end

    book = @request.book
    ActivityTracker.track("request.cancelled", trackable: @request)
    @request.destroy!

    # Clean up orphaned books with no requests and no file
    if book.requests.empty? && !book.acquired?
      book.destroy
    end

    redirect_to destroy_redirect_location, notice: "Request cancelled", status: :see_other
  end

  def retry
    unless Current.user.admin?
      redirect_back fallback_location: @request, alert: "You don't have permission to retry requests"
      return
    end

    @request.retry_now!
    redirect_back fallback_location: @request, notice: "Request has been queued for retry."
  end

  def manual_magnet
    unless Current.user.admin?
      redirect_to @request, alert: "You don't have permission to add magnet links"
      return
    end

    @request.add_manual_magnet!(params[:magnet_url])
    redirect_to @request, notice: "Magnet link queued for download."
  rescue ArgumentError => e
    redirect_to @request, alert: e.message
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    redirect_to @request, alert: "Magnet link could not be queued. Please try again."
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
      # Books imported with a blank path template share the output root as
      # their file_path; zipping it would bundle the entire library
      if output_root_path?(path)
        redirect_to @request, alert: "This book was imported directly into the library folder and cannot be downloaded as a bundle"
        return
      end

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

  def output_root_path?(path)
    expanded_path = File.expand_path(path)

    [
      SettingsService.get(:audiobook_output_path),
      SettingsService.get(:ebook_output_path)
    ].compact.reject(&:blank?).any? { |root| File.expand_path(root) == expanded_path }
  end

  def set_request
    @request = if Current.user.admin?
      Request.includes(:search_results).find(params[:id])
    else
      Request.for_user(Current.user).includes(:search_results).find(params[:id])
    end
  end

  # Allow any user to download from any request if the book is acquired
  # This enables shared library access where users can download books added by others
  def set_request_for_download
    @request = Request.find(params[:id])
    unless @request.book.acquired?
      redirect_to library_index_path, alert: "This book is not available for download"
    end
  end

  def record_not_found
    head :not_found
  end

  def destroy_redirect_location
    return requests_path if request.referer.blank?

    referer_path = URI.parse(request.referer).path
    return requests_path if referer_path == request_path(@request)

    request.referer
  rescue URI::InvalidURIError
    requests_path
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

  def remove_associated_torrents(request)
    request.downloads.each do |download|
      next unless download.external_id.present? && download.download_client.present?

      begin
        client = download.download_client.adapter
        client.remove_torrent(download.external_id, delete_files: false)
        Rails.logger.info "[RequestsController] Removed torrent #{download.external_id} for download ##{download.id}"
      rescue DownloadClients::Base::Error => e
        Rails.logger.warn "[RequestsController] Failed to remove torrent: #{e.message}"
      end
    end
  end

  def request_metadata_attrs
    {
      title: params[:title],
      author: params[:author],
      cover_url: params[:cover_url],
      first_publish_year: params[:first_publish_year]
    }
  end
end
