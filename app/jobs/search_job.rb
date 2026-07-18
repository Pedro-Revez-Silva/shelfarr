# frozen_string_literal: true

class SearchJob < ApplicationJob
  queue_as :default

  SearchAttempt = Data.define(:name, :query, :score_penalty)

  GENERIC_SEARCH_ATTEMPT_PENALTIES = {
    exact_title: 0,
    title_author: 5,
    short_title: 6,
    author_title: 8,
    normalized_title: 10,
    number_variant: 12
  }.freeze

  # How many below-threshold broad results to keep when a search would
  # otherwise come back empty, so users see low-confidence candidates
  # instead of no results at all.
  LOW_CONFIDENCE_FALLBACK_LIMIT = 5

  ROMAN_NUMERALS = {
    "I" => "1",
    "II" => "2",
    "III" => "3",
    "IV" => "4",
    "V" => "5",
    "VI" => "6",
    "VII" => "7",
    "VIII" => "8",
    "IX" => "9",
    "X" => "10",
    "XI" => "11",
    "XII" => "12",
    "XIII" => "13",
    "XIV" => "14",
    "XV" => "15"
  }.freeze
  ARABIC_NUMERALS = ROMAN_NUMERALS.invert.freeze
  # Standalone "I" is almost always the pronoun ("I, Robot"), not a series number,
  # so it is excluded when generating roman -> arabic query variants.
  ROMAN_VARIANT_NUMERALS = ROMAN_NUMERALS.except("I").freeze

  def perform(request_id)
    suppress_database_debug_logging { perform_search(request_id) }
  end

  private

  def perform_search(request_id)
    request = Request.find_by(id: request_id)
    return unless request
    search_generation = claim_search!(request)
    return unless search_generation

    Rails.logger.info "[SearchJob] Starting search for request ##{request.id}"

    # Check if any search sources are configured
    indexer_available = IndexerClient.configured?
    anna_available = AnnaArchiveClient.configured? && request.book.ebook?
    zlibrary_available = ZLibraryClient.configured? && request.book.ebook?
    gutenberg_available = GutenbergClient.configured? && request.book.ebook?
    librivox_available = LibrivoxClient.configured? && request.book.audiobook?
    custom_providers = AcquisitionProvider.enabled.for_book_type(request.book.book_type).by_priority.to_a
    store_providers = StoreProviderRegistry.enabled_for(request.book.book_type)

    unless indexer_available || anna_available || zlibrary_available || gutenberg_available || librivox_available || custom_providers.any? || store_providers.any?
      Rails.logger.error "[SearchJob] No search sources configured"
      handle_no_search_sources(request, search_generation)
      return
    end

    all_results = []
    all_store_offers = []
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

    if gutenberg_available
      gutenberg_results = search_gutenberg(request)
      all_results.concat(gutenberg_results)
      Rails.logger.info "[SearchJob] Found #{gutenberg_results.count} Project Gutenberg results"
    end

    if librivox_available
      librivox_results = search_librivox(request)
      all_results.concat(librivox_results)
      Rails.logger.info "[SearchJob] Found #{librivox_results.count} LibriVox results"
    end

    custom_providers.each do |provider|
      provider_results = search_custom_provider(request, provider)
      all_results.concat(provider_results)
      Rails.logger.info "[SearchJob] Found #{provider_results.count} custom provider results from #{provider.name}"
    end

    store_providers.each do |provider|
      provider_offers = search_store_provider(request, provider)
      all_store_offers.concat(provider_offers)
      Rails.logger.info "[SearchJob] Found #{provider_offers.count} DRM-free store offers from #{provider.name}"
    end

    complete_search(
      request,
      search_generation,
      results: all_results,
      store_offers: all_store_offers,
      indexer_error: indexer_error
    )
  end

  def claim_search!(request)
    claimed_at = Time.current
    generation = request.class.transaction do
      claimed = request.class
        .where(id: request.id, status: :pending)
        .where.not(book_id: nil)
        .update_all(
          status: Request.statuses.fetch("searching"),
          search_generation: Arel.sql("search_generation + 1"),
          search_claimed_at: claimed_at,
          attention_needed: false,
          issue_description: nil,
          updated_at: claimed_at
        )
      next unless claimed == 1

      request.reload.search_generation
    end
    request.broadcast_show_refresh_later if generation
    generation
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def handle_no_search_sources(request, search_generation)
    request.with_search_transition_lock do
      unless owns_search_attempt?(request, search_generation)
        log_stale_search(request)
        next false
      end

      request.mark_for_attention!("No search sources configured. Please configure an indexer, Anna's Archive, Z-Library, Project Gutenberg, LibriVox, a DRM-free store, or a custom acquisition provider.")
      clear_search_claim!(request)
      true
    end
  rescue ActiveRecord::RecordNotFound
    false
  end

  def complete_search(request, search_generation, results:, store_offers:, indexer_error:)
    request.with_search_transition_lock do
      unless owns_search_attempt?(request, search_generation)
        log_stale_search(request)
        next false
      end

      # A provider can be disabled or switch market while its network request
      # is in flight. Revalidate the captured results after acquiring the
      # request lock so that race cannot create an awaiting state whose offers
      # are already hidden by the current configuration.
      store_offers = currently_eligible_store_offers(request, store_offers)
      save_store_offers(request, store_offers)

      if results.any?
        save_results(request, results)
        Rails.logger.info "[SearchJob] Total #{results.count} results for request ##{request.id}"
        attempt_auto_select(request)
      elsif store_offers.any?
        Rails.logger.info "[SearchJob] Store offers found for request ##{request.id}; awaiting purchase or import"
        handle_store_offers(request, store_offers.count)
      else
        Rails.logger.info "[SearchJob] No results found for request ##{request.id}"
        handle_no_results(request, indexer_error)
      end

      clear_search_claim!(request)
      true
    end
  rescue ActiveRecord::RecordNotFound
    false
  end

  def owns_search_attempt?(request, search_generation)
    request.persisted? && request.searching? && request.search_generation == search_generation
  end

  def clear_search_claim!(request)
    request.update_column(:search_claimed_at, nil)
  end

  def log_stale_search(request)
    Rails.logger.info "[SearchJob] Request ##{request.id} search ownership changed; discarding stale search results"
  end

  def search_indexer_safely(request)
    results = search_indexer(request)
    [ results, nil ]
  rescue IndexerClients::Base::AuthenticationError => e
    Rails.logger.error "[SearchJob] #{IndexerClient.display_name} authentication failed (#{e.class})"
    [ [], e ]
  rescue IndexerClients::Base::ConnectionError => e
    Rails.logger.error "[SearchJob] #{IndexerClient.display_name} connection error for request ##{request.id} (#{e.class})"
    [ [], e ]
  rescue IndexerClients::Base::Error => e
    Rails.logger.error "[SearchJob] #{IndexerClient.display_name} error for request ##{request.id} (#{e.class})"
    [ [], e ]
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

  def handle_store_offers(request, count)
    request.update!(
      status: :awaiting_purchase,
      attention_needed: false,
      issue_description: nil,
      next_retry_at: nil
    )
    RequestEvent.record!(
      request: request,
      event_type: "store_offers_found",
      source: "store_provider",
      message: "#{count} DRM-free store #{'offer'.pluralize(count)} found",
      details: { offer_count: count }
    )
  end

  def search_indexer(request)
    if IndexerClient.provider == SearchResult::SOURCE_PROWLARR
      tagged_results = search_prowlarr(request)
    else
      tagged_results = search_generic_indexer(request)
    end

    tagged_results.map do |tagged|
      tagged.merge(source: IndexerClient.provider)
    end
  end

  def search_prowlarr(request)
    book = request.book
    query = indexer_language_hint(request)
    categories = primary_indexer_categories(request)

    Rails.logger.debug "[SearchJob] Searching #{IndexerClient.display_name} for request ##{request.id} (type: #{book.book_type})"

    structured_results = tag_indexer_results(
      IndexerClient.search(
        query,
        book_type: book.book_type,
        categories: categories,
        title: book.title,
        author: book.author
      ),
      attempt: SearchAttempt.new(name: :structured_book, query: query, score_penalty: 0)
    )

    results = structured_results

    if structured_results.empty?
      Rails.logger.info "[SearchJob] #{IndexerClient.display_name} book search returned no results for request ##{request.id}; retrying with a generic query"
      results = merge_indexer_results(results, search_generic_indexer_attempts(request, categories: categories, starting_results: results))
    elsif book.ebook?
      Rails.logger.info "[SearchJob] #{IndexerClient.display_name} ebook search found #{structured_results.count} structured results for request ##{request.id}; supplementing with a generic query"
      results = merge_indexer_results(results, search_generic_indexer_attempts(request, categories: categories, starting_results: results))
    elsif !strong_indexer_match?(results, request)
      Rails.logger.info "[SearchJob] #{IndexerClient.display_name} book search found no strong match for request ##{request.id}; supplementing with a generic query"
      results = merge_indexer_results(results, search_generic_indexer_attempts(request, categories: categories, starting_results: results))
    end

    finalize_indexer_results(request, results)
  end

  def search_generic_indexer(request)
    book = request.book
    categories = primary_indexer_categories(request)
    Rails.logger.debug "[SearchJob] Searching #{IndexerClient.display_name} for request ##{request.id} (type: #{book.book_type})"

    results = search_generic_indexer_attempts(request, categories: categories)
    finalize_indexer_results(request, results)
  end

  def generic_indexer_query(request)
    [ request.book.title, indexer_language_hint(request) ].reject(&:blank?).join(" ")
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
    Rails.logger.debug "[SearchJob] Searching Anna's Archive for request ##{request.id}"

    results = AnnaArchiveClient.search(query, language: language)

    # Tag results with source
    results.map do |r|
      { result: r, source: SearchResult::SOURCE_ANNA_ARCHIVE }
    end
  rescue AnnaArchiveClient::BotProtectionError => e
    Rails.logger.warn "[SearchJob] Anna's Archive bot protection for request ##{request.id} (#{e.class})"
    # Store the error message to show user if no other results
    @anna_archive_bot_protection_error = e.message
    []
  rescue AnnaArchiveClient::Error => e
    Rails.logger.warn "[SearchJob] Anna's Archive search failed for request ##{request.id} (#{e.class})"
    []
  end

  def search_zlibrary(request)
    book = request.book
    query = [ book.title, book.author ].compact.join(" ")
    language = zlibrary_language_filter(request)
    Rails.logger.debug "[SearchJob] Searching Z-Library for request ##{request.id}"

    ZLibraryClient.search(query, language: language).map do |result|
      { result: result, source: SearchResult::SOURCE_ZLIBRARY }
    end
  rescue ZLibraryClient::Error => e
    Rails.logger.warn "[SearchJob] Z-Library search failed for request ##{request.id} (#{e.class})"
    []
  end

  def search_librivox(request)
    book = request.book
    language = request.effective_language
    Rails.logger.debug "[SearchJob] Searching LibriVox for request ##{request.id}"

    LibrivoxClient.search(title: book.title, author: book.author, language: language).map do |result|
      { result: result, source: SearchResult::SOURCE_LIBRIVOX }
    end
  rescue LibrivoxClient::Error => e
    Rails.logger.warn "[SearchJob] LibriVox search failed for request ##{request.id} (#{e.class})"
    []
  end

  def search_gutenberg(request)
    book = request.book
    language = request.effective_language
    Rails.logger.debug "[SearchJob] Searching Project Gutenberg for request ##{request.id}"

    GutenbergClient.search(title: book.title, author: book.author, language: language).map do |result|
      { result: result, source: SearchResult::SOURCE_GUTENBERG }
    end
  rescue GutenbergClient::Error => e
    Rails.logger.warn "[SearchJob] Project Gutenberg search failed for request ##{request.id} (#{e.class})"
    []
  end

  def search_custom_provider(request, provider)
    provider.client.search(request).select(&:downloadable?).map do |result|
      { result: result, source: SearchResult::SOURCE_CUSTOM, provider: provider }
    end
  rescue CustomAcquisitionProviderClient::Error => e
    Rails.logger.warn "[SearchJob] Custom provider #{provider.name} search failed for request ##{request.id} (#{e.class})"
    []
  end

  def search_store_provider(request, provider)
    book = request.book
    provider.client.search(
      title: book.title,
      author: book.author,
      isbn: book.isbn,
      language: request.effective_language
    ).map do |result|
      { result: result, provider: provider }
    end
  rescue StoreProviderError => e
    Rails.logger.warn "[SearchJob] Store provider #{provider.name} search failed for request ##{request.id} (#{e.class})"
    []
  end

  def currently_eligible_store_offers(request, tagged_offers)
    current_providers = StoreProviderRegistry.enabled_for(request.book.book_type).index_by(&:key)

    tagged_offers.select do |tagged|
      current_provider = current_providers[tagged[:provider].key]
      next false unless current_provider

      current_market = current_provider.market
      current_market.blank? || tagged[:result].market.to_s.strip.upcase == current_market
    end
  end

  def save_store_offers(request, tagged_offers)
    request.store_offers.delete_all

    tagged_offers.each do |tagged|
      result = tagged[:result]
      provider = tagged[:provider]

      request.store_offers.create!(
        provider: provider.key,
        external_id: result.id,
        title: result.title,
        author: result.author,
        isbns: result.isbns,
        language: result.language,
        formats: result.formats,
        market: result.market,
        drm_free: true,
        drm_type: result.drm_type,
        price_amount: result.price_amount,
        price_currency: result.price_currency,
        localized_price: result.localized_price,
        storefront_url: result.storefront_url,
        checkout_url: result.checkout_url,
        cover_url: result.cover_url,
        quoted_at: result.quoted_at
      )
    end
  end

  def save_results(request, tagged_results)
    blocklisted_by_guid = request.search_results
      .where.not(source: SearchResult::MANUAL_SOURCES)
      .blocklisted
      .pluck(:guid, :blocklisted_at, :blocklist_reason)
      .to_h { |guid, blocklisted_at, blocklist_reason| [ guid, { blocklisted_at: blocklisted_at, blocklist_reason: blocklist_reason } ] }

    active_download_result_ids = request.downloads
      .where(status: [ :queued, :downloading, :paused ])
      .where.not(search_result_id: nil)
      .distinct
      .pluck(:search_result_id)

    request.search_results
      .where.not(source: SearchResult::MANUAL_SOURCES)
      .where.not(id: active_download_result_ids)
      .not_blocklisted
      .destroy_all

    tagged_results.each do |tagged|
      result = tagged[:result]
      source = tagged[:source]

      search_result = case source
      when SearchResult::SOURCE_ANNA_ARCHIVE
        save_anna_archive_result(request, result)
      when SearchResult::SOURCE_ZLIBRARY
        save_zlibrary_result(request, result)
      when SearchResult::SOURCE_GUTENBERG
        save_gutenberg_result(request, result)
      when SearchResult::SOURCE_LIBRIVOX
        save_librivox_result(request, result)
      when SearchResult::SOURCE_CUSTOM
        save_custom_provider_result(request, result, tagged[:provider])
      else
        save_indexer_result(request, result, source)
      end

      if search_result
        if (blocklist_attrs = blocklisted_by_guid[search_result.guid])
          search_result.update!(blocklist_attrs.merge(status: :rejected))
        end
        search_result.calculate_score!
        apply_search_attempt_penalty!(search_result, tagged)
      end
    end
  end

  def save_indexer_result(request, result, source)
    search_result = request.search_results.find_or_initialize_by(guid: result.guid)
    search_result.assign_attributes(
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
    search_result.status = :pending unless search_result.blocklisted? || search_result.selected?
    search_result.save!
    search_result
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
      sr.info_url = AnnaArchiveClient.info_url(result.md5)
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

  def save_librivox_result(request, result)
    request.search_results.find_or_create_by!(guid: "librivox:#{result.id}") do |sr|
      sr.title = build_librivox_title(result)
      sr.indexer = "LibriVox"
      sr.size_bytes = nil
      sr.seeders = nil
      sr.leechers = nil
      sr.download_url = result.download_url
      sr.magnet_url = nil
      sr.info_url = result.info_url
      sr.published_at = nil
      sr.source = SearchResult::SOURCE_LIBRIVOX
      sr.detected_language = result.language
    end
  end

  def save_gutenberg_result(request, result)
    request.search_results.find_or_create_by!(guid: "gutenberg:#{result.id}") do |sr|
      sr.title = build_direct_source_title(result)
      sr.indexer = "Project Gutenberg"
      sr.size_bytes = nil
      sr.seeders = nil
      sr.leechers = nil
      sr.download_url = result.download_url
      sr.magnet_url = nil
      sr.info_url = result.info_url
      sr.published_at = nil
      sr.source = SearchResult::SOURCE_GUTENBERG
      sr.detected_language = result.language
    end
  end

  def save_custom_provider_result(request, result, provider)
    request.search_results.find_or_create_by!(
      acquisition_provider: provider,
      provider_result_id: result.provider_result_id
    ) do |sr|
      sr.guid = "custom:#{provider.id}:#{result.provider_result_id}"
      sr.title = build_custom_provider_title(result)
      sr.indexer = provider.name
      sr.size_bytes = result.size_bytes
      sr.seeders = nil
      sr.leechers = nil
      sr.download_url = result.download_url
      sr.magnet_url = result.magnet_url
      sr.info_url = result.info_url
      sr.published_at = result.published_at
      sr.source = SearchResult::SOURCE_CUSTOM
      sr.detected_language = result.language
      sr.provider_payload = result.payload
    end
  end

  def build_custom_provider_title(result)
    parts = []
    parts << result.title if result.title.present?
    parts << "- #{result.author}" if result.author.present?
    parts << "[#{result.file_type.to_s.upcase}]" if result.file_type.present?
    parts << "[#{result.language}]" if result.language.present?
    parts.join(" ")
  end

  def build_librivox_title(result)
    parts = []
    parts << result.title if result.title.present?
    parts << "- #{result.author}" if result.author.present?
    parts << "[AUDIOBOOK ZIP]"
    parts << "[#{result.language_display_name}]" if result.respond_to?(:language_display_name) && result.language_display_name.present?
    parts << "(#{result.year})" if result.year.present?
    parts.join(" ")
  end

  def build_direct_source_title(result)
    parts = []
    parts << result.title if result.title.present?
    parts << "- #{result.author}" if result.author.present?
    parts << "[#{result.file_type.upcase}]" if result.file_type.present?
    parts << "[#{result.language_display_name}]" if result.respond_to?(:language_display_name) && result.language_display_name.present?
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

  def merge_indexer_results(*result_groups)
    seen = {}

    result_groups.flatten.compact.each_with_object([]) do |tagged_result, merged|
      result = indexer_result_from(tagged_result)
      key = result.guid.presence || [ result.indexer, result.title, result.download_link ].join("|")
      next if seen[key]

      seen[key] = true
      merged << normalize_tagged_indexer_result(tagged_result)
    end
  end

  def finalize_indexer_results(request, results)
    if SettingsService.unrestricted_indexer_search_scope?
      filtered = filter_broad_results(results, request)
      results = filtered.any? ? filtered : low_confidence_fallback_results(results, request)
    end
    supplement_with_broad_search(request, results)
  end

  def supplement_with_broad_search(request, results)
    return results unless SettingsService.broad_indexer_search_scope?

    attempts = generic_indexer_attempts(request)
    return results if attempts.empty?

    Rails.logger.info "[SearchJob] Supplementing #{IndexerClient.display_name} search for request ##{request.id} without category restrictions"

    broad_results = search_generic_indexer_attempts(request, categories: [], starting_results: results, attempts: attempts)
    merged = merge_indexer_results(results, filter_broad_results(broad_results, request))
    return merged if merged.any?

    low_confidence_fallback_results(broad_results, request)
  rescue IndexerClients::Base::Error => e
    Rails.logger.warn "[SearchJob] #{IndexerClient.display_name} broad search failed for request ##{request.id} (#{e.class})"
    results
  end

  def primary_indexer_categories(request)
    SettingsService.indexer_category_ids_for(request.book.book_type)
  end

  def strong_indexer_match?(results, request)
    threshold = SettingsService.get(:min_match_confidence)

    Array(results).any? do |tagged_result|
      result = indexer_result_from(tagged_result)
      next false if ReleaseParserService.video_release?(result.title)
      next false if SettingsService.unrestricted_indexer_search_scope? &&
        !compatible_result_categories?(result, request.book.book_type)

      penalized_indexer_score(tagged_result, request) >= threshold
    end
  end

  # Scores a result the same way save_results will persist it: the raw
  # ReleaseScorer total minus the search attempt penalty. Keeping threshold
  # checks on the penalized score prevents broadened attempts from stopping
  # the search with a result that ends up stored below the confidence threshold.
  def penalized_indexer_score(tagged_result, request)
    result = indexer_result_from(tagged_result)
    score = ReleaseScorer.score(search_result_for_scoring(result), request).total
    penalty = tagged_result.is_a?(Hash) ? tagged_result[:score_penalty].to_i : 0
    [ score - penalty, 0 ].max
  end

  def search_result_for_scoring(result)
    SearchResult.new(
      title: result.title,
      seeders: result.seeders,
      download_url: result.download_url,
      magnet_url: result.magnet_url
    )
  end

  def filter_broad_results(results, request)
    threshold = SettingsService.get(:min_match_confidence)

    Array(results).select do |tagged_result|
      broad_result_candidate?(tagged_result, request) &&
        penalized_indexer_score(tagged_result, request) >= threshold
    end
  end

  # Baseline sanity check for results found without category restrictions:
  # category tags (when present) must be compatible with the book type, and
  # the release name must not look like video content.
  def broad_result_candidate?(tagged_result, request)
    result = indexer_result_from(tagged_result)
    compatible_result_categories?(result, request.book.book_type) &&
      !ReleaseParserService.video_release?(result.title)
  end

  # When every result was filtered out, an empty list hides that the broad
  # search did retrieve plausible candidates. Keep the best few below the
  # confidence threshold — clearly penalized and ranked last — so users can
  # judge them instead of resorting to manual searches.
  def low_confidence_fallback_results(results, request)
    candidates = Array(results).select { |tagged_result| broad_result_candidate?(tagged_result, request) }
    return [] if candidates.empty?

    kept = candidates
      .sort_by { |tagged_result| -penalized_indexer_score(tagged_result, request) }
      .first(LOW_CONFIDENCE_FALLBACK_LIMIT)
    Rails.logger.info "[SearchJob] No results met the confidence threshold for request ##{request.id}; keeping #{kept.count} low-confidence candidates"
    kept
  end

  def compatible_result_categories?(result, book_type)
    category_ids = Array(result.category_ids).map(&:to_i)
    standard_category_ids = category_ids.select { |id| id.between?(1000, 7999) }
    return true if standard_category_ids.empty?

    case book_type&.to_sym
    when :audiobook
      standard_category_ids.any? { |id| id.between?(3000, 3999) }
    when :ebook
      standard_category_ids.any? { |id| id.between?(7000, 7999) }
    when :comicbook
      standard_category_ids.any? { |id| id.between?(7030, 7039) }
    else
      true
    end
  end

  def search_generic_indexer_attempts(request, categories:, starting_results: [], attempts: nil)
    attempts ||= generic_indexer_attempts(request)
    results = []
    last_error = nil

    attempts.each do |attempt|
      Rails.logger.debug "[SearchJob] Searching #{IndexerClient.display_name} for request ##{request.id} (attempt: #{attempt.name})"

      begin
        attempt_results = tag_indexer_results(
          IndexerClient.search(attempt.query, book_type: request.book.book_type, categories: categories),
          attempt: attempt
        )
        results = merge_indexer_results(results, attempt_results)
      rescue IndexerClients::Base::AuthenticationError
        # Every remaining attempt would fail the same way; let the caller surface it.
        raise
      rescue IndexerClients::Base::Error => e
        Rails.logger.warn "[SearchJob] #{IndexerClient.display_name} generic attempt failed for request ##{request.id} (attempt: #{attempt.name}, error: #{e.class})"
        last_error = e
      end

      break if strong_indexer_match?(merge_indexer_results(starting_results, results), request)
    end

    # If nothing was found anywhere and at least one attempt errored, propagate
    # so the caller treats this as an indexer failure rather than an empty search.
    raise last_error if last_error && results.empty? && Array(starting_results).empty?

    results
  end

  def generic_indexer_attempts(request)
    book = request.book
    language_hint = indexer_language_hint(request)
    attempts = [
      build_search_attempt(:exact_title, [ book.title, language_hint ]),
      build_search_attempt(:title_author, [ book.title, book.author, language_hint ])
    ]

    short_title = short_search_title(book.title)
    attempts << build_search_attempt(:short_title, [ short_title, book.author, language_hint ]) if short_title.present?

    attempts << build_search_attempt(:author_title, [ book.author, book.title, language_hint ])
    attempts << build_search_attempt(:normalized_title, [ normalized_search_title(book.title), language_hint ])

    numeric_title_variants(book.title).each do |title_variant|
      attempts << build_search_attempt(:number_variant, [ title_variant, language_hint ])
      attempts << build_search_attempt(:number_variant, [ title_variant, book.author, language_hint ])
    end

    deduplicate_search_attempts(attempts)
  end

  def suppress_database_debug_logging(&block)
    logger = ActiveRecord::Base.logger
    return yield unless logger&.respond_to?(:silence)

    logger.silence(Logger::INFO, &block)
  end

  def build_search_attempt(name, parts)
    query = parts.compact_blank.join(" ").squish
    SearchAttempt.new(
      name: name,
      query: query,
      score_penalty: GENERIC_SEARCH_ATTEMPT_PENALTIES.fetch(name, 0)
    )
  end

  def deduplicate_search_attempts(attempts)
    seen = {}
    attempts.select do |attempt|
      normalized_query = attempt.query.downcase
      next false if attempt.query.blank? || seen[normalized_query]

      seen[normalized_query] = true
    end
  end

  # Book metadata often carries subtitles that release names omit
  # ("Mistborn: The Final Empire", "Project Hail Mary: A Novel").
  # Returns the title up to the first subtitle separator, or nil when the
  # title has no subtitle or the remainder is too short to search safely.
  def short_search_title(title)
    short = title.to_s.split(/\s*(?::|;|–|—|\s-\s)\s*/, 2).first.to_s.squish
    return nil if short.blank? || short.casecmp?(title.to_s.squish)
    return nil if short.length < 4

    short
  end

  def normalized_search_title(title)
    title.to_s
      .gsub(/\([^)]*\)|\[[^\]]*\]/, " ")
      .gsub(/\b(?:volume|vol\.?|book|part)\s+(\d+)\b/i, "\\1")
      .gsub(/['’]/, "")
      .gsub(/[[:punct:]]+/, " ")
      .squish
  end

  def numeric_title_variants(title)
    values = Set.new
    text = title.to_s

    ROMAN_VARIANT_NUMERALS.each do |roman, number|
      values << text.gsub(/\b#{Regexp.escape(roman)}\b/i, number) if text.match?(/\b#{Regexp.escape(roman)}\b/i)
    end

    ARABIC_NUMERALS.each do |number, roman|
      values << text.gsub(/\b#{Regexp.escape(number)}\b/, roman) if text.match?(/\b#{Regexp.escape(number)}\b/)
    end

    values.delete(text)
    values.first(6)
  end

  def tag_indexer_results(results, attempt:)
    Array(results).map do |result|
      {
        result: result,
        score_penalty: attempt.score_penalty,
        search_attempt: attempt.name.to_s,
        search_query: attempt.query
      }
    end
  end

  def normalize_tagged_indexer_result(tagged_result)
    return tagged_result if tagged_result.is_a?(Hash) && tagged_result.key?(:result)

    {
      result: tagged_result,
      score_penalty: 0,
      search_attempt: "unknown",
      search_query: nil
    }
  end

  def indexer_result_from(tagged_result)
    tagged_result.is_a?(Hash) && tagged_result.key?(:result) ? tagged_result[:result] : tagged_result
  end

  def apply_search_attempt_penalty!(search_result, tagged)
    penalty = tagged[:score_penalty].to_i
    attempt = tagged[:search_attempt]
    query = tagged[:search_query]
    return if penalty <= 0 && attempt.blank? && query.blank?

    breakdown = search_result.score_breakdown || {}
    breakdown["search_attempt"] = attempt
    breakdown["search_query"] = query
    breakdown["search_penalty"] = penalty

    search_result.update!(
      confidence_score: [ search_result.confidence_score.to_i - penalty, 0 ].max,
      score_breakdown: breakdown
    )
  end
end
