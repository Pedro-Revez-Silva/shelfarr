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
        request.schedule_retry!
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

    request.search_results.create!(
      guid: result.md5,  # Use MD5 as unique identifier
      title: build_anna_title(result),
      indexer: "Anna's Archive",
      size_bytes: size_bytes,
      seeders: nil,  # N/A for Anna's Archive
      leechers: nil,
      download_url: nil,  # Will be fetched via API when downloading
      magnet_url: nil,
      info_url: "#{SettingsService.get(:anna_archive_url)}/md5/#{result.md5}",
      published_at: nil,
      source: SearchResult::SOURCE_ANNA_ARCHIVE,
      detected_language: result.language
    )
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
    return unless SettingsService.get(:auto_select_enabled, default: false)

    result = AutoSelectService.call(request)

    if result.success?
      Rails.logger.info "[SearchJob] Auto-selected result for request ##{request.id}"
    end
    # If not successful, request stays in :searching for manual selection
  end
end
