# frozen_string_literal: true

class RequestsController < ApplicationController
  class UnsafeDownloadPathError < StandardError; end
  DownloadBoundary = Data.define(:target, :root, :device, :inode, :kind)
  UnscopedLibraryMatch = Data.define(:match, :book_types)
  MAX_ARCHIVE_DOWNLOAD_FILENAME_BYTES = 120
  LIBRARY_ID_SETTING_KEYS = %i[
    audiobookshelf_audiobook_library_id
    audiobookshelf_ebook_library_id
    audiobookshelf_comicbook_library_id
    audiobookshelf_audiobook_scan_library_ids
    audiobookshelf_ebook_scan_library_ids
    audiobookshelf_comicbook_scan_library_ids
  ].freeze

  before_action :set_request, only: [ :show, :destroy, :retry, :manual_magnet, :manual_nzb ]
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

    # Pagination to limit fuzzy matching overhead
    @requests_page = params[:page].to_i.clamp(1, 1_000_000)
    @requests_per_page = 25
    @requests_total_count = @requests.count
    @requests_total_pages = [ (@requests_total_count.to_f / @requests_per_page).ceil, 1 ].max
    @requests_page = @requests_page.clamp(1, @requests_total_pages)
    @requests = @requests.limit(@requests_per_page).offset((@requests_page - 1) * @requests_per_page)

    # Preload library matches for admin (used for "In Library" pill on each card).
    # Scope candidates to the library IDs configured for each book type so an
    # ebook copy doesn't mark an audiobook request as "In Library".
    # Deduplicate by book_id to avoid re-matching the same book across multiple requests.
    @library_matches_by_book = if Current.user&.admin? && LibraryItem.available_for_matching.exists?
      matcher = AudiobookshelfLibraryMatcherService.new
      @requests.map(&:book).uniq.each_with_object({}) do |book, hash|
        hash[book.id] = matcher.matches_for(
          title: book.title,
          author: book.author,
          limit: 1,
          library_ids: library_ids_for_book_type(book.book_type)
        )
      end
    else
      {}
    end
  end

  def library_ids_for_book_type(book_type)
    settings = library_id_settings
    return nil if settings.values.all?(&:empty?) # Preserve all-library matching after auto-discovery.

    library_ids = case book_type.to_s
    when "audiobook"
      settings[:audiobookshelf_audiobook_library_id] + settings[:audiobookshelf_audiobook_scan_library_ids]
    when "comicbook"
      delivery_ids = settings[:audiobookshelf_comicbook_library_id].presence ||
                     settings[:audiobookshelf_ebook_library_id]
      delivery_ids + settings[:audiobookshelf_comicbook_scan_library_ids]
    else # ebook
      settings[:audiobookshelf_ebook_library_id] + settings[:audiobookshelf_ebook_scan_library_ids]
    end

    library_ids.uniq.sort
  end

  def library_id_settings
    @library_id_settings ||= LIBRARY_ID_SETTING_KEYS.index_with do |key|
      SettingsService.get(key).to_s.split(",").map(&:strip).filter_map(&:presence).uniq
    end
  end

  def explicitly_assigned_library_ids_by_book_type
    settings = library_id_settings
    {
      "audiobook" => settings[:audiobookshelf_audiobook_library_id] + settings[:audiobookshelf_audiobook_scan_library_ids],
      "ebook" => settings[:audiobookshelf_ebook_library_id] + settings[:audiobookshelf_ebook_scan_library_ids],
      "comicbook" => settings[:audiobookshelf_comicbook_library_id] + settings[:audiobookshelf_comicbook_scan_library_ids]
    }.transform_values { |ids| ids.uniq.sort }
  end
  private :library_ids_for_book_type, :library_id_settings, :explicitly_assigned_library_ids_by_book_type

  def show
    @request_events = Current.user.admin? ? @request.request_events.recent.limit(10) : RequestEvent.none
    @store_offers = StoreProviderRegistry.visible_offers_for(@request).best_first.to_a
  end

  def new
    return if redirect_legacy_description_handoff?

    cached_metadata = request_handoff_metadata
    @work_id = params[:work_id].presence || cached_metadata[:work_id]
    @source_work_ids = [ *Array(params[:source_work_ids]), *Array(cached_metadata[:source_work_ids]) ].compact_blank.uniq
    metadata = resolved_new_request_metadata(cached_metadata)
    @title = metadata[:title]
    @author = metadata[:author]
    @cover_url = metadata[:cover_url]
    @first_publish_year = metadata[:first_publish_year]
    @content_kind = ContentKinds.resolve(
      metadata[:content_kind],
      source_work_ids: [ @work_id, *@source_work_ids ],
      collection_source: metadata[:collection_source],
      default: ContentKinds::BOOK
    )
    @description = metadata[:description]
    @publisher = metadata[:publisher]
    @issue_number = metadata[:issue_number]
    @release_date = metadata[:release_date]
    @series = metadata[:series]
    @series_position = metadata[:series_position]
    @request_scope = metadata[:request_scope].presence || "single"
    @collection_source = metadata[:collection_source]
    @collection_id = metadata[:collection_id]
    @collection_title = metadata[:collection_title]
    @available_book_types = RequestOptionPolicy.book_types_for(@content_kind)

    if @work_id.blank? || @title.blank?
      redirect_to search_path, alert: "Missing book information"
      return
    end

    load_synced_library_matches
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
      source_work_ids: params[:source_work_ids],
      collection_item_ids: params[:collection_item_ids]
    )

    if result.queued?
      redirect_to requests_path, notice: "Collection request queued. Individual requests will appear here shortly."
    elsif result.created_requests.empty?
      redirect_to search_path, alert: result.errors.join(". ")
    elsif result.created_requests.length == 1
      flash_message = "Request created for #{result.created_requests.first.book.display_name}"
      flash_message += " (#{result.warnings.join(', ')})" if result.warnings.any?
      flash[:alert] = result.errors.join(". ") if result.errors.any?
      redirect_to result.created_requests.first, notice: flash_message
    else
      flash_message = "#{result.created_requests.length} requests created for #{result.created_requests.first.book.title}"
      flash_message += " (#{result.warnings.join(', ')})" if result.warnings.any?
      flash[:alert] = result.errors.join(". ") if result.errors.any?
      redirect_to requests_path, notice: flash_message
    end
  end

  def destroy
    unless @request.user == Current.user || Current.user.admin?
      redirect_to requests_path, alert: "You cannot cancel this request"
      return
    end

    # A direct acquisition may have a complete atomic publication which has
    # not yet been committed to Book/Request state. Keep its recovery owner
    # durable instead of cascading the Download row away. Recovery either
    # finalizes those bytes or safely removes stale private staging later.
    if @request.direct_acquisition_recovery_pending?
      @request.cancel!(allow_direct_recovery: true)
      DirectDownloadRecoveryJob.perform_later
      redirect_to @request,
        notice: "Request cancellation recorded. Direct download cleanup will finish in the background.",
        status: :see_other
      return
    end

    # This durable, idempotent claim is the authoritative cancellation guard.
    # It makes the request non-fulfillable and stops active Download rows under
    # the same lock used by upload/Audible admission before any external or
    # activity-log side effect is attempted.
    @request.claim_destructive_cancellation!

    # Optionally remove torrent from download client
    if params[:remove_torrent] == "1"
      remove_associated_torrents(@request)
    end

    book = @request.book
    @request.destroy!
    ActivityTracker.track("request.cancelled", trackable: @request)

    # Clean up orphaned books with no requests and no file
    if book.requests.empty? && !book.acquisition_blocked?
      book.destroy
    end

    redirect_to destroy_redirect_location, notice: "Request cancelled", status: :see_other
  rescue ActiveRecord::RecordNotDestroyed, Request::CancellationBlockedError => error
    message = error.respond_to?(:record) ? error.record.errors.full_messages.to_sentence : error.message
    redirect_to @request,
      alert: message.presence || @request.upload_cancellation_blocked_message,
      status: :see_other
  end

  def retry
    unless Current.user.admin?
      redirect_back fallback_location: @request, alert: "You don't have permission to retry requests"
      return
    end

    outcome = @request.retry_now!
    case outcome
    when :post_processing_recovery_pending
      redirect_back fallback_location: @request,
        alert: "The immediate post-processing retry could not be queued. " \
          "Its durable recovery claim was kept and the watchdog will retry it automatically."
    when :active
      redirect_back fallback_location: @request, notice: "Post-processing recovery is already active."
    when :superseded
      redirect_back fallback_location: @request,
        notice: "Another post-processing recovery attempt took ownership."
    else
      redirect_back fallback_location: @request, notice: "Request has been queued for retry."
    end
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

  def manual_nzb
    unless Current.user.admin?
      redirect_to @request, alert: "You don't have permission to add NZB URLs"
      return
    end

    @request.add_manual_nzb!(params[:nzb_url])
    redirect_to @request, notice: "NZB URL queued for download."
  rescue ArgumentError => e
    redirect_to @request, alert: e.message
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    redirect_to @request, alert: "NZB URL could not be queued. Please try again."
  end

  def download
    book = @request.book

    unless book.acquired? && book.file_path.present?
      redirect_to @request, alert: "This book is not available for download"
      return
    end

    begin
      boundary = canonical_download_boundary(book.file_path)
    rescue Errno::ENOENT
      redirect_to @request, alert: "File not found on server"
      return
    rescue UnsafeDownloadPathError, SystemCallError, ArgumentError
      Rails.logger.warn(
        "[Security] Rejected unsafe library download path for request ##{@request.id}, book ##{book.id}"
      )
      redirect_to @request, alert: "Invalid file path"
      return
    end

    if boundary.kind == :directory
      # Books imported with a blank path template share the output root as
      # their file_path; zipping it would bundle the entire library
      if boundary.target == boundary.root
        redirect_to @request, alert: "This book was imported directly into the library folder and cannot be downloaded as a bundle"
        return
      end

      send_zipped_directory(boundary.target, book, output_root: boundary.root)
    else
      send_single_file(boundary, book)
    end
  end

  private

  def send_single_file(boundary, book)
    path = boundary.target
    filename = File.basename(path)
    file = FileCopyService.open_pinned_regular_file(
      path,
      root: boundary.root,
      expected_device: boundary.device,
      expected_inode: boundary.inode
    )
    send_pinned_file(
      file,
      filename: filename,
      type: Marcel::MimeType.for(name: filename) || "application/octet-stream"
    )
  rescue Errno::ENOENT, ActionController::MissingFile
    file&.close unless file&.closed?
    redirect_to @request, alert: "File not found on server"
  rescue UnsafeDownloadPathError, FileCopyService::UnsafePathError, SystemCallError, ArgumentError
    file&.close unless file&.closed?
    Rails.logger.warn(
      "[Security] Rejected changed library download target for request ##{@request.id}, book ##{book.id}"
    )
    redirect_to @request, alert: "Invalid file path"
  end

  def send_zipped_directory(path, book, output_root:)
    zip_filename = archive_download_filename(book)
    cached_zip_path = LibraryDownloadArchiveService.call(
      book: book,
      source_path: path,
      output_root: output_root
    )

    cache_stat = File.lstat(cached_zip_path)
    cache_file = FileCopyService.open_pinned_regular_file(
      cached_zip_path,
      root: LibraryDownloadArchiveService::CACHE_DIRECTORY.to_s,
      expected_device: cache_stat.dev,
      expected_inode: cache_stat.ino
    )
    send_pinned_file(cache_file, filename: zip_filename, type: "application/zip")
  rescue LibraryDownloadArchiveService::ResourceLimitError => e
    cache_file&.close unless cache_file&.closed?
    Rails.logger.warn "[Download] Archive resource limit for book ##{book.id}: #{e.class}"
    redirect_to @request, alert: "This library item exceeds the safe archive limits and cannot be bundled."
  rescue LibraryDownloadArchiveService::BusyError => e
    cache_file&.close unless cache_file&.closed?
    Rails.logger.warn "[Download] Archive capacity unavailable for book ##{book.id}: #{e.class}"
    redirect_to @request, alert: "Archive preparation is busy. Please try again shortly."
  rescue LibraryDownloadArchiveService::Error, FileCopyService::UnsafePathError,
    ActionController::MissingFile, SystemCallError => e
    cache_file&.close unless cache_file&.closed?
    Rails.logger.error "[Download] Error creating zip for book ##{book.id}: #{e.class}"
    redirect_to @request, alert: "Library files changed while preparing the download. Please try again."
  end

  def send_pinned_file(file, filename:, type:)
    body = PinnedFileResponseBody.new(file)
    send_file_headers!(filename: filename, type: type, disposition: "attachment")
    headers["Content-Length"] = file.stat.size.to_s
    self.status = :ok
    self.response_body = body
    body = nil
  ensure
    body&.close
  end

  def archive_download_filename(book)
    extension = ".zip"
    byte_budget = MAX_ARCHIVE_DOWNLOAD_FILENAME_BYTES - extension.bytesize
    value = "#{book.author} - #{book.title}".encode(
      Encoding::UTF_8,
      invalid: :replace,
      undef: :replace,
      replace: "_"
    ).unicode_normalize(:nfc)
    value = value.gsub(/[\/\\:*?"<>|\x00-\x1f\x7f]/, "_").strip
    value = "library-download" if value.blank?
    value = value.byteslice(0, byte_budget).to_s.force_encoding(Encoding::UTF_8).scrub("_")
    value = value.sub(/[ .]+\z/, "")
    value = "library-download" if value.blank?
    "#{value}#{extension}"
  end

  def canonical_download_boundary(path)
    raise UnsafeDownloadPathError, "library path is blank" if path.blank?

    canonical_target = Pathname(path).expand_path.realpath
    target_stat = File.lstat(canonical_target)
    kind = if target_stat.file?
      :file
    elsif target_stat.directory?
      :directory
    else
      raise UnsafeDownloadPathError, "library target is not a regular file or directory"
    end

    canonical_root = canonical_output_roots.select do |root|
      canonical_path_contained?(canonical_target.to_s, root.to_s)
    end.max_by { |root| root.to_s.length }
    raise UnsafeDownloadPathError, "library path resolves outside configured roots" unless canonical_root

    DownloadBoundary.new(
      target: canonical_target.to_s,
      root: canonical_root.to_s,
      device: target_stat.dev,
      inode: target_stat.ino,
      kind: kind
    )
  end

  def allowed_output_paths
    [
      SettingsService.get(:audiobook_output_path),
      SettingsService.get(:ebook_output_path),
      SettingsService.get(:comicbook_output_path)
    ].compact.reject(&:blank?)
  end

  def canonical_path_contained?(path, root)
    return true if path == root

    root_prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
    path.start_with?(root_prefix)
  end

  def canonical_output_roots
    allowed_output_paths.filter_map do |configured_root|
      candidate = Pathname(configured_root).expand_path.realpath
      next if candidate.root?
      next unless candidate.lstat.directory?

      candidate
    rescue SystemCallError, ArgumentError
      nil
    end.uniq
  end

  def set_request
    @request = if Current.user.admin?
      Request.includes(:search_results, :store_offers).find(params[:id])
    else
      Request.for_user(Current.user).includes(:search_results, :store_offers).find(params[:id])
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

    referer = URI.parse(request.referer)
    referer_path = referer.path.to_s
    return requests_path if referer.host.present? && referer.host != request.host
    return requests_path unless referer_path.start_with?("/")
    return requests_path if referer_path.start_with?("//") || referer_path.include?("\\")
    return requests_path if referer_path == request_path(@request)

    referer.query.present? ? "#{referer_path}?#{referer.query}" : referer_path
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

  def load_synced_library_matches
    @synced_library_matches_by_book_type = {}
    @unscoped_synced_library_match_entries = []
    return if @request_scope == "collection" || @available_book_types.empty?

    matcher = AudiobookshelfLibraryMatcherService.new(cache_library_items: false)
    all_library_scopes = %w[audiobook ebook comicbook].index_with do |book_type|
      library_ids_for_book_type(book_type)
    end

    if all_library_scopes.values.all?(&:nil?)
      match = matcher.matches_for(title: @title, author: @author, limit: 1).first
      @unscoped_synced_library_match_entries << UnscopedLibraryMatch.new(
        match: match,
        book_types: @available_book_types
      ) if match
      return
    end

    library_scopes = all_library_scopes.slice(*@available_book_types)
    overlapping_ids = explicitly_assigned_library_ids_by_book_type.values.flatten.tally.filter_map do |id, count|
      id if count > 1
    end
    if library_id_settings[:audiobookshelf_comicbook_library_id].empty?
      overlapping_ids |= library_id_settings[:audiobookshelf_ebook_library_id]
    end
    overlapping_ids &= library_scopes.values.compact.flatten
    overlapping_ids.each do |library_id|
      match = matcher.matches_for(
        title: @title,
        author: @author,
        limit: 1,
        library_ids: [ library_id ]
      ).first
      next unless match

      book_types = library_scopes.filter_map do |book_type, library_ids|
        book_type if Array(library_ids).include?(library_id)
      end
      @unscoped_synced_library_match_entries << UnscopedLibraryMatch.new(match: match, book_types: book_types)
    end

    @synced_library_matches_by_book_type = library_scopes.transform_values do |library_ids|
      scoped_ids = Array(library_ids) - overlapping_ids
      matcher.matches_for(title: @title, author: @author, limit: 1, library_ids: scoped_ids)
    end
  end

  def request_handoff_metadata
    metadata = RequestMetadataHandoff.fetch(user: Current.user, token: params[:metadata_token])
    return metadata if params[:work_id].blank? || metadata[:work_id] == params[:work_id]

    {}
  end

  def redirect_legacy_description_handoff?
    return false if params[:metadata_token].present? || params[:description].blank?

    metadata = request_metadata_attrs.merge(
      work_id: params[:work_id],
      source_work_ids: params[:source_work_ids]
    )
    redirect_to new_request_path(RequestMetadataHandoff.params_for(user: Current.user, metadata: metadata))
    true
  end

  def resolved_new_request_metadata(cached_metadata)
    lookup_metadata = if cached_metadata.empty?
      BookMetadataLookupService.call(
        [ @work_id, *@source_work_ids ],
        fallback: request_metadata_attrs
      ).tap do |metadata|
        metadata[:first_publish_year] ||= metadata.delete(:year)
      end
    else
      {}
    end

    lookup_metadata.merge(request_metadata_attrs.compact).merge(cached_metadata)
  end

  def remove_associated_torrents(request)
    request.downloads.each do |download|
      next unless download.external_id.present? && download.download_client.present?

      begin
        client = download.download_client.adapter
        client.remove_torrent(download.external_id, delete_files: false)
        Rails.logger.info "[RequestsController] Removed torrent for download ##{download.id}"
      rescue DownloadClients::Base::Error => e
        Rails.logger.warn(
          "[RequestsController] Failed to remove torrent for download ##{download.id}: #{e.class}"
        )
      end
    end
  end

  def request_metadata_attrs
    {
      title: params[:title],
      author: params[:author],
      cover_url: params[:cover_url],
      first_publish_year: params[:first_publish_year],
      description: params[:description],
      publisher: params[:publisher],
      content_kind: params[:content_kind],
      issue_number: params[:issue_number],
      release_date: params[:release_date],
      series: params[:series],
      series_position: params[:series_position],
      request_scope: params[:request_scope],
      collection_source: params[:collection_source],
      collection_id: params[:collection_id],
      collection_title: params[:collection_title]
    }
  end
end
