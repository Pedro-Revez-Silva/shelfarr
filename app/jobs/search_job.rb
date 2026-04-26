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
    indexer_available = IndexerClient.configured?
    anna_available = AnnaArchiveClient.configured? && request.book.ebook?
    zlibrary_available = !anna_available && ZLibraryClient.configured? && request.book.ebook?

    unless indexer_available || anna_available || zlibrary_available
      Rails.logger.error "[SearchJob] No search sources configured"
      request.mark_for_attention!("No search sources configured. Please configure an indexer, Anna's Archive, or Z-Library in Admin Settings.")
      return
    end

    all_results = []
    indexer_error = nil

    if indexer_available
      indexer_results, indexer_error = search_indexer_safely(request)
      all_results.concat(indexer_results)
      Rails.logger.info "[SearchJob] Found #{indexer_results.count} #{IndexerClient.display_name} results"
    end

    # Search Anna's Archive for ebooks if configured
    if anna_available
      anna_results = search_anna_archive(request)
      all_results.concat(anna_results)
      Rails.logger.info "[SearchJob] Found #{anna_results.count} Anna's Archive results"
    end

    if zlibrary_available
      zlibrary_results = search_zlibrary(request)
      all_results.concat(zlibrary_results)
      Rails.logger.info "[SearchJob] Found #{zlibrary_results.count} Z-Library results"
    end

    if all_results.any?
      save_results(request, all_results)
      Rails.logger.info "[SearchJob] Total #{all_results.count} results for request ##{request.id}"
      attempt_auto_select(request)
    else
      Rails.logger.info "[SearchJob] No results found for request ##{request.id}"
      handle_no_results(request, indexer_error)
    end
  end

  private

  def search_indexer_safely(request)
    results = search_indexer(request)
    [results, nil]
  rescue IndexerClients::Base::AuthenticationError => e
    Rails.logger.error "[SearchJob] #{IndexerClient.display_name} authentication failed: #{e.message}"
    [[], e]
  rescue IndexerClients::Base::ConnectionError => e
    Rails.logger.error "[SearchJob] #{IndexerClient.display_name} connection error for request ##{request.id}: #{e.message}"
    [[], e]
  rescue IndexerClients::Base::Error => e
    Rails.logger.error "[SearchJob] #{IndexerClient.display_name} error for request ##{request.id}: #{e.message}"
    [[], e]
  end

  def handle_no_results(request, indexer_error)
    if @anna_archive_bot_protection_error
      request.mark_for_attention!(@anna_archive_bot_protection_error)
    elsif indexer_error.is_a?(IndexerClients::Base::AuthenticationError)
      request.mark_for_attention!("#{IndexerClient.display_name} authentication failed. Please check your API key.")
    else
      request.schedule_retry!
    end
  end

  def search_indexer(request)
    if IndexerClient.provider == SearchResult::SOURCE_PROWLARR
      results = search_prowlarr(request)
    else
      results = search_generic_indexer(request)
    end

    results.map do |r|
      { result: r, source: IndexerClient.provider }
    end
  end

  def search_prowlarr(request)
    book = request.book
    query = indexer_language_hint(request)

    Rails.logger.debug "[SearchJob] Searching #{IndexerClient.display_name} book query for title='#{book.title}' author='#{book.author}' extra='#{query}' (type: #{book.book_type})"

    results = IndexerClient.search(
      query,
      book_type: book.book_type,
      title: book.title,
      author: book.author
    )

    return results if results.any?

    fallback_queries = prowlarr_fallback_queries(request)

    fallback_queries.each_with_index do |fallback_query, index|
      Rails.logger.info "[SearchJob] #{IndexerClient.display_name} book search returned no results for request ##{request.id}; retrying with generic query #{index + 1}/#{fallback_queries.size}: '#{fallback_query}'"
      fallback_results = IndexerClient.search(fallback_query, book_type: book.book_type)
      return fallback_results if fallback_results.any?
    end

    []
  end

  def search_generic_indexer(request)
    book = request.book
    query = generic_indexer_query(request)
    Rails.logger.debug "[SearchJob] Searching #{IndexerClient.display_name} for: #{query} (type: #{book.book_type})"

    IndexerClient.search(query, book_type: book.book_type)
  end

  def generic_indexer_query(request)
    [ request.book.title, indexer_language_hint(request) ].reject(&:blank?).join(" ")
  end

  def prowlarr_fallback_queries(request)
    language_hint = indexer_language_hint(request)
    title_variants = normalized_query_variants(request.book.title)

    title_variants.map do |title|
      [ title, language_hint ].reject(&:blank?).join(" ")
    end.uniq
  end

  def normalized_query_variants(value)
    base = value.to_s.squish
    return [] if base.blank?

    apostrophe_normalized = base.tr("’‘`´", "'").squish
    apostrophe_removed = apostrophe_normalized.delete("'").squish
    punctuation_simplified = apostrophe_removed.gsub(/[^\p{Alnum}\s]/, " ").squish

    variants = [
      base,
      apostrophe_normalized,
      apostrophe_removed,
      punctuation_simplified
    ].reject(&:blank?)

    (variants + variants.map(&:downcase)).reject(&:blank?).uniq
  end

  def indexer_language_hint(request)
    return nil unless should_add_language_to_search?(request)

    language_search_term(request)
  end

  def search_anna_archive(request)
    book = request.book

    query_parts = [ book.title ]
    query_parts << book.author if book.author.present?
    query = query_parts.join(" ")

    # Pass language to Anna's Archive for better filtering
    language = request.effective_language
    Rails.logger.debug "[SearchJob] Searching Anna's Archive for: #{query} (language: #{language})"

    results = AnnaArchiveClient.search(query, language: language)

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

  def search_zlibrary(request)
    book = request.book
    query = [book.title, book.author].compact.join(" ")
    language = zlibrary_language_filter(request)
    Rails.logger.debug "[SearchJob] Searching Z-Library for: #{query} (language: #{language || 'any'})"

    ZLibraryClient.search(query, language: language).map do |result|
      { result: result, source: SearchResult::SOURCE_ZLIBRARY }
    end
  rescue ZLibraryClient::Error => e
    Rails.logger.warn "[SearchJob] Z-Library search failed: #{e.message}"
    []
  end

  def save_results(request, tagged_results)
    request.search_results.destroy_all

    tagged_results.each do |tagged|
      result = tagged[:result]
      source = tagged[:source]

      search_result = case source
      when SearchResult::SOURCE_ANNA_ARCHIVE
        save_anna_archive_result(request, result)
      when SearchResult::SOURCE_ZLIBRARY
        save_zlibrary_result(request, result)
      else
        save_indexer_result(request, result, source)
      end

      search_result.calculate_score! if search_result
    end
  end

  def save_indexer_result(request, result, source)
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
      source: source
    )
  end

  def save_anna_archive_result(request, result)
    # Convert file size string to bytes for sorting
    size_bytes = parse_size_to_bytes(result.file_size)

    # Use find_or_create_by to handle duplicate MD5s in Anna's Archive results
    request.search_results.find_or_create_by!(guid: result.md5) do |sr|
      sr.title = build_direct_source_title(result)
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

  def save_zlibrary_result(request, result)
    request.search_results.find_or_create_by!(guid: "#{result.id}:#{result.hash}") do |sr|
      sr.title = build_direct_source_title(result)
      sr.indexer = "Z-Library"
      sr.size_bytes = result.file_size
      sr.seeders = nil
      sr.leechers = nil
      sr.download_url = nil
      sr.magnet_url = nil
      sr.info_url = nil
      sr.published_at = nil
      sr.source = SearchResult::SOURCE_ZLIBRARY
      sr.detected_language = result.language
    end
  end

  def build_direct_source_title(result)
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

  def zlibrary_language_filter(request)
    info = ReleaseParserService.language_info(request.effective_language)
    info&.dig(:name)&.downcase
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

  # Check if we should add language to the search query
  # Only add for non-English languages that we have a name for
  def should_add_language_to_search?(request)
    language = request.effective_language
    return false if language.blank? || language == "en"

    # Only add if we have a known language name
    info = ReleaseParserService.language_info(language)
    info.present?
  end

  # Get the language name for search query
  def language_search_term(request)
    language = request.effective_language
    info = ReleaseParserService.language_info(language)
    info[:name]
  end
end
