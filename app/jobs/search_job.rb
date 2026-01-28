# frozen_string_literal: true

class SearchJob < ApplicationJob
  queue_as :default

  def perform(request_id)
    request = Request.find_by(id: request_id)
    return unless request
    return unless request.pending?
    return unless request.book # Guard against orphaned requests

    Rails.logger.info "[SearchJob] Starting search for request ##{request.id} (book: #{request.book.title})"

    request.update!(status: :searching)

    # Check if any search sources are configured
    prowlarr_available = ProwlarrClient.configured?
    anna_available = AnnaArchiveClient.configured? && request.book.ebook?

    unless prowlarr_available || anna_available
      Rails.logger.error "[SearchJob] No search sources configured"
      request.mark_for_attention!("No search sources configured. Please configure Prowlarr or Anna's Archive in Admin Settings.")
      return
    end

    begin
      all_results = []

      # Search Prowlarr if configured
      if prowlarr_available
        prowlarr_results = search_prowlarr(request)
        all_results.concat(prowlarr_results)
        Rails.logger.info "[SearchJob] Found #{prowlarr_results.count} Prowlarr results"
      end

      # Search Anna's Archive for ebooks if configured
      if anna_available
        anna_results = search_anna_archive(request)
        all_results.concat(anna_results)
        Rails.logger.info "[SearchJob] Found #{anna_results.count} Anna's Archive results"
      end

      if all_results.any?
        save_results(request, all_results)
        Rails.logger.info "[SearchJob] Total #{all_results.count} results for request ##{request.id}"
        attempt_auto_select(request)
      else
        Rails.logger.info "[SearchJob] No results found for request ##{request.id}"
        # If bot protection was detected and no results from other sources, mark for attention
        if @anna_archive_bot_protection_error
          request.mark_for_attention!(@anna_archive_bot_protection_error)
        else
          request.schedule_retry!
        end
      end
    rescue ProwlarrClient::AuthenticationError => e
      Rails.logger.error "[SearchJob] Prowlarr authentication failed: #{e.message}"
      request.mark_for_attention!("Prowlarr authentication failed. Please check your API key.")
    rescue ProwlarrClient::ConnectionError => e
      Rails.logger.error "[SearchJob] Prowlarr connection error for request ##{request.id}: #{e.message}"
      request.schedule_retry!
    rescue ProwlarrClient::Error => e
      Rails.logger.error "[SearchJob] Prowlarr error for request ##{request.id}: #{e.message}"
      request.schedule_retry!
    rescue AnnaArchiveClient::Error => e
      Rails.logger.error "[SearchJob] Anna's Archive error for request ##{request.id}: #{e.message}"
      # Non-fatal - continue if Prowlarr had results
    end
  end

  private

  def search_prowlarr(request)
    book = request.book

    # Build search query: "title author"
    query_parts = [ book.title ]
    query_parts << book.author if book.author.present?

    query = query_parts.join(" ")
    Rails.logger.debug "[SearchJob] Searching Prowlarr for: #{query} (type: #{book.book_type})"

    # Search with appropriate category filter for book type
    results = ProwlarrClient.search(query, book_type: book.book_type)

    # Tag results with source
    results.map do |r|
      { result: r, source: SearchResult::SOURCE_PROWLARR }
    end
  end

  def search_anna_archive(request)
    book = request.book

    query_parts = [ book.title ]
    query_parts << book.author if book.author.present?
    query = query_parts.join(" ")

    Rails.logger.debug "[SearchJob] Searching Anna's Archive for: #{query}"

    results = AnnaArchiveClient.search(query)

    # Tag results with source
    results.map do |r|
      { result: r, source: SearchResult::SOURCE_ANNA_ARCHIVE }
    end
  rescue AnnaArchiveClient::BotProtectionError => e
    Rails.logger.warn "[SearchJob] Anna's Archive bot protection: #{e.message}"
    # Store the error message to show user if no other results
    @anna_archive_bot_protection_error = e.message
    []
  rescue AnnaArchiveClient::Error => e
    Rails.logger.warn "[SearchJob] Anna's Archive search failed: #{e.message}"
    []
  end

  def save_results(request, tagged_results)
    request.search_results.destroy_all

    tagged_results.each do |tagged|
      result = tagged[:result]
      source = tagged[:source]

      search_result = if source == SearchResult::SOURCE_ANNA_ARCHIVE
        save_anna_archive_result(request, result)
      else
        save_prowlarr_result(request, result)
      end

      search_result.calculate_score! if search_result
    end
  end

  def save_prowlarr_result(request, result)
    request.search_results.create!(
      guid: result.guid,
      title: result.title,
      indexer: result.indexer,
      size_bytes: result.size_bytes,
      seeders: result.seeders,
      leechers: result.leechers,
      download_url: result.download_url,
      magnet_url: result.magnet_url,
      info_url: result.info_url,
      published_at: result.published_at,
      source: SearchResult::SOURCE_PROWLARR
    )
  end

  def save_anna_archive_result(request, result)
    # Convert file size string to bytes for sorting
    size_bytes = parse_size_to_bytes(result.file_size)

    # Use find_or_create_by to handle duplicate MD5s in Anna's Archive results
    request.search_results.find_or_create_by!(guid: result.md5) do |sr|
      sr.title = build_anna_title(result)
      sr.indexer = "Anna's Archive"
      sr.size_bytes = size_bytes
      sr.seeders = nil  # N/A for Anna's Archive
      sr.leechers = nil
      sr.download_url = nil  # Will be fetched via API when downloading
      sr.magnet_url = nil
      sr.info_url = "#{SettingsService.get(:anna_archive_url)}/md5/#{result.md5}"
      sr.published_at = nil
      sr.source = SearchResult::SOURCE_ANNA_ARCHIVE
      sr.detected_language = result.language
    end
  end

  def build_anna_title(result)
    parts = []
    parts << result.title if result.title.present?
    parts << "- #{result.author}" if result.author.present?
    parts << "[#{result.file_type.upcase}]" if result.file_type.present?
    parts << "(#{result.year})" if result.year.present?
    parts.join(" ")
  end

  def parse_size_to_bytes(size_string)
    return nil if size_string.blank?

    match = size_string.match(/(\d+(?:\.\d+)?)\s*(KB|MB|GB)/i)
    return nil unless match

    value = match[1].to_f
    unit = match[2].upcase

    case unit
    when "KB" then (value * 1024).to_i
    when "MB" then (value * 1024 * 1024).to_i
    when "GB" then (value * 1024 * 1024 * 1024).to_i
    else nil
    end
  end

  def attempt_auto_select(request)
    unless SettingsService.get(:auto_select_enabled, default: false)
      # Auto-select disabled, flag for manual selection
      request.mark_for_attention!("Search results found. Please review and select a result to download.")
      Rails.logger.info "[SearchJob] Auto-select disabled, flagged for manual selection for request ##{request.id}"
      return
    end

    result = AutoSelectService.call(request)

    if result.success?
      Rails.logger.info "[SearchJob] Auto-selected result for request ##{request.id}"
    else
      # Auto-select failed to find a suitable result, flag for manual selection
      request.mark_for_attention!("Search results found but none matched auto-select criteria. Please review and select a result manually.")
      Rails.logger.info "[SearchJob] Auto-select failed, flagged for manual selection for request ##{request.id}"
    end
  end
end
