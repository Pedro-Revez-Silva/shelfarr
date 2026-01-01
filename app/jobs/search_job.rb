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

    begin
      results = search_prowlarr(request)

      if results.any?
        save_results(request, results)
        Rails.logger.info "[SearchJob] Found #{results.count} results for request ##{request.id}"
        attempt_auto_select(request)
      else
        Rails.logger.info "[SearchJob] No results found for request ##{request.id}"
        request.schedule_retry!
      end
    rescue ProwlarrClient::NotConfiguredError => e
      Rails.logger.error "[SearchJob] Prowlarr not configured: #{e.message}"
      request.mark_for_attention!("Prowlarr is not configured. Please configure Prowlarr in Admin Settings.")
    rescue ProwlarrClient::AuthenticationError => e
      Rails.logger.error "[SearchJob] Prowlarr authentication failed: #{e.message}"
      request.mark_for_attention!("Prowlarr authentication failed. Please check your API key.")
    rescue ProwlarrClient::ConnectionError => e
      Rails.logger.error "[SearchJob] Prowlarr connection error for request ##{request.id}: #{e.message}"
      request.schedule_retry!
    rescue ProwlarrClient::Error => e
      Rails.logger.error "[SearchJob] Prowlarr error for request ##{request.id}: #{e.message}"
      request.schedule_retry!
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
    ProwlarrClient.search(query, book_type: book.book_type)
  end

  def save_results(request, results)
    request.search_results.destroy_all

    results.each do |result|
      search_result = request.search_results.create!(
        guid: result.guid,
        title: result.title,
        indexer: result.indexer,
        size_bytes: result.size_bytes,
        seeders: result.seeders,
        leechers: result.leechers,
        download_url: result.download_url,
        magnet_url: result.magnet_url,
        info_url: result.info_url,
        published_at: result.published_at
      )

      search_result.calculate_score!
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
