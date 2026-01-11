# frozen_string_literal: true

class LibraryController < ApplicationController
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def index
    @books = Book.acquired.includes(:requests).order(updated_at: :desc)
    @books = @books.where(book_type: params[:type]) if params[:type].present?
  end

  def show
    @book = Book.acquired.find(params[:id])
    @user_request = @book.requests.completed.first
  end

  def destroy
    unless Current.user.admin?
      redirect_to library_index_path, alert: "Only admins can delete books from the library"
      return
    end

    @book = Book.find(params[:id])

    # Optionally remove torrents from download clients
    if params[:remove_torrent] == "1"
      remove_associated_torrents(@book)
    end

    # Delete book files from disk if requested
    # Also removes from Audiobookshelf if configured
    if params[:delete_files] == "1" && @book.file_path.present?
      delete_from_audiobookshelf(@book)
      delete_book_files(@book)
    end

    # Track activity before destroying
    ActivityTracker.track("book.deleted", trackable: @book, user: Current.user)

    # Destroy all associated requests and the book
    @book.requests.destroy_all
    @book.destroy!

    redirect_to library_index_path, notice: "\"#{@book.title}\" has been removed from the library"
  end

  private

  def record_not_found
    head :not_found
  end

  def remove_associated_torrents(book)
    book.requests.each do |request|
      request.downloads.each do |download|
        next unless download.external_id.present? && download.download_client.present?

        begin
          client = download.download_client.adapter
          client.remove_torrent(download.external_id, delete_files: false)
          Rails.logger.info "[LibraryController] Removed torrent #{download.external_id} for download ##{download.id}"
        rescue DownloadClients::Base::Error => e
          Rails.logger.warn "[LibraryController] Failed to remove torrent: #{e.message}"
        end
      end
    end
  end

  def delete_book_files(book)
    path = book.file_path
    return unless path.present?

    # Security: Validate path is within allowed directories
    unless path_within_allowed_directories?(path)
      Rails.logger.warn "[LibraryController] Attempted to delete file outside allowed directories: #{path}"
      return
    end

    if File.exist?(path)
      if File.directory?(path)
        FileUtils.rm_rf(path)
        Rails.logger.info "[LibraryController] Deleted directory: #{path}"
      else
        FileUtils.rm_f(path)
        Rails.logger.info "[LibraryController] Deleted file: #{path}"
      end
    end
  rescue => e
    Rails.logger.error "[LibraryController] Failed to delete files: #{e.message}"
  end

  def path_within_allowed_directories?(path)
    return false if path.blank?

    expanded_path = File.expand_path(path)
    allowed_paths = [
      SettingsService.get(:audiobook_output_path),
      SettingsService.get(:ebook_output_path)
    ].compact.reject(&:blank?)

    allowed_paths.any? do |allowed|
      expanded_allowed = File.expand_path(allowed)
      expanded_path.start_with?(expanded_allowed + "/") || expanded_path == expanded_allowed
    end
  end

  def delete_from_audiobookshelf(book)
    return unless AudiobookshelfClient.configured?
    return unless book.file_path.present?

    if AudiobookshelfClient.delete_item_by_path(book.file_path)
      Rails.logger.info "[LibraryController] Deleted book from Audiobookshelf: #{book.file_path}"
    else
      Rails.logger.warn "[LibraryController] Book not found in Audiobookshelf: #{book.file_path}"
    end
  rescue AudiobookshelfClient::Error => e
    Rails.logger.error "[LibraryController] Failed to delete from Audiobookshelf: #{e.message}"
  end
end
