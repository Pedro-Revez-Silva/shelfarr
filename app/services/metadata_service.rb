# frozen_string_literal: true

# Unified service for fetching book metadata from configured sources
# Orchestrates Hardcover, Google Books, and OpenLibrary based on settings
class MetadataService
  class Error < StandardError; end

  SearchResult = Data.define(
    :source, :source_id, :title, :author, :description, :year,
    :cover_url, :has_audiobook, :has_ebook, :series_name, :series_position
  ) do
    def work_id
      "#{source}:#{source_id}"
    end

    # Compatibility with OpenLibrary patterns
    def first_publish_year
      year
    end

    def cover_id
      nil
    end

    def source_name
      MetadataSources.display_name(source)
    end

    def source_url
      case source.to_s
      when "hardcover"
        "https://hardcover.app/books/#{source_id}" if source_id.present?
      when "google_books"
        "https://books.google.com/books?id=#{source_id}" if source_id.present?
      when "openlibrary"
        "https://openlibrary.org/works/#{source_id}" if source_id.present?
      end
    end

    def source_attribution
      "Metadata from #{source_name}"
    end

    def google_books?
      source.to_s == "google_books"
    end
  end

  class << self
    # Search for books across enabled metadata sources and aggregate duplicates
    # into Shelfarr candidates.
    def search(query, limit: nil, content_kind: nil)
      content_kind = ContentKinds.normalize(content_kind, default: nil)
      providers = enabled_metadata_providers(content_kind: content_kind)
      Rails.logger.info "[MetadataService] Searching '#{query}' using providers: #{providers.join(', ')}"

      provider_results = search_providers_concurrently(providers, query, limit: limit, content_kind: content_kind)
      aggregate_provider_results(provider_results, limit: limit, content_kind: content_kind)
    end

    def each_provider_search(query, limit: nil, content_kind: nil)
      content_kind = ContentKinds.normalize(content_kind, default: nil)
      providers = enabled_metadata_providers(content_kind: content_kind)
      return enum_for(__method__, query, limit: limit, content_kind: content_kind) unless block_given?

      queue = Queue.new
      threads = providers.map do |provider|
        Thread.new do
          Rails.application.executor.wrap do
            ActiveRecord::Base.connection_pool.with_connection do
              queue << [ provider, search_provider(provider, query, limit: limit, content_kind: content_kind) ]
            end
          end
        rescue StandardError => e
          Rails.logger.warn "[MetadataService] #{provider} search failed: #{e.message}"
          queue << [ provider, [] ]
        end
      end

      providers.size.times do
        yield queue.pop
      end
    ensure
      threads&.each(&:join)
    end

    def search_provider(provider, query, limit: nil, content_kind: nil)
      content_kind = ContentKinds.normalize(content_kind, default: nil)
      status = MetadataProviderStatus.for_provider(provider)
      unless status.available?
        Rails.logger.info "[MetadataService] Skipping #{provider}: #{status.status}"
        return []
      end

      results = if content_kind.present?
        send("search_#{provider}", query, provider_limit(provider, limit), content_kind: content_kind)
      else
        send("search_#{provider}", query, provider_limit(provider, limit))
      end
      status.record_success!
      results
    rescue *provider_errors(provider) => e
      status&.record_failure!(e)
      Rails.logger.warn "[MetadataService] #{provider} search failed: #{e.message}"
      []
    end

    def aggregate_provider_results(provider_results, limit: nil, content_kind: nil)
      requested_content_kind = ContentKinds.normalize(content_kind, default: nil)
      candidates = MetadataSearch::Aggregator.call(
        provider_results,
        priority: provider_priority,
        requested_content_kind: requested_content_kind
      )
      min_confidence = SettingsService.get(:min_match_confidence).to_i
      candidates = candidates.select { |candidate| candidate.confidence >= min_confidence }
      candidates = filter_candidates_for_content(candidates, requested_content_kind)
      sort_candidates(candidates, requested_content_kind: requested_content_kind).first(limit || default_search_limit)
    end

    def merge_provider_results(results_by_provider)
      ordered_provider_results(results_by_provider)
    end

    # Get book details by unified work_id (format: "source:id")
    def book_details(work_id)
      source, id = parse_work_id(work_id)

      Rails.logger.info "[MetadataService] Fetching details for #{work_id}"

      case source
      when "hardcover"
        fetch_hardcover_details(id)
      when "google_books"
        fetch_google_books_details(id)
      when "openlibrary", "OL"
        fetch_openlibrary_details(id)
      when "comic_vine"
        ComicVineClient.details(id)
      else
        raise ArgumentError, "Unknown metadata source: #{source}"
      end
    end

    # Test all configured metadata sources
    def test_connections
      results = {}

      if HardcoverClient.configured?
        results[:hardcover] = HardcoverClient.test_connection rescue false
      end

      if GoogleBooksClient.configured?
        results[:google_books] = GoogleBooksClient.test_connection rescue false
      end

      if OpenLibraryClient.configured?
        results[:openlibrary] = OpenLibraryClient.test_connection rescue false
      end

      if ComicVineClient.configured?
        results[:comic_vine] = ComicVineClient.test_connection rescue false
      end

      results
    end

    # Determine primary metadata source
    def metadata_source
      SettingsService.get(:metadata_source, default: "auto")
    end

    def enabled_metadata_providers(content_kind: nil)
      SettingsService.enabled_metadata_providers
    end

    def provider_priority
      SettingsService.metadata_provider_priority
    end

    # Check if any metadata source is available
    def available?
      enabled_metadata_providers.any?
    end

    private

    def provider_errors(provider)
      errors = case provider.to_s
      when "hardcover"
        [ HardcoverClient::Error ]
      when "google_books"
        [ GoogleBooksClient::Error ]
      when "openlibrary"
        [ OpenLibraryClient::Error ]
      when "comic_vine"
        [ ComicVineClient::Error ]
      else
        [ StandardError ]
      end
      errors << VCR::Errors::UnhandledHTTPRequestError if defined?(VCR::Errors::UnhandledHTTPRequestError)
      errors << WebMock::NetConnectNotAllowedError if defined?(WebMock::NetConnectNotAllowedError)
      errors
    end

    def search_hardcover(query, limit, content_kind: nil)
      return [] unless HardcoverClient.configured?

      results = HardcoverClient.search(query, limit: limit)
      results.map do |result|
        MetadataSearch::ResultNormalizer.call("hardcover", result, requested_content_kind: content_kind)
      end
    end

    def search_openlibrary(query, limit, content_kind: nil)
      return [] unless OpenLibraryClient.configured?

      results = OpenLibraryClient.search(query, limit: limit)
      results.map do |result|
        MetadataSearch::ResultNormalizer.call("openlibrary", result, requested_content_kind: content_kind)
      end
    end

    def search_google_books(query, limit, content_kind: nil)
      return [] unless GoogleBooksClient.configured?

      results = GoogleBooksClient.search(query, limit: limit)
      results.map do |result|
        MetadataSearch::ResultNormalizer.call("google_books", result, requested_content_kind: content_kind)
      end
    end

    def search_comic_vine(query, limit, content_kind: nil)
      return [] unless ComicVineClient.configured?

      results = ComicVineClient.search(query, limit: limit, content_kind: content_kind)
      results.map { |result| MetadataSearch::ResultNormalizer.call("comic_vine", result) }
    end

    def search_providers_concurrently(providers, query, limit: nil, content_kind: nil)
      results_by_provider = collect_provider_results(providers, query, limit: limit, content_kind: content_kind)
      ordered_provider_results(results_by_provider)
    end

    def collect_provider_results(providers, query, limit: nil, content_kind: nil)
      results_by_provider = {}
      queue = Queue.new
      threads = providers.map do |provider|
        Thread.new do
          Rails.application.executor.wrap do
            ActiveRecord::Base.connection_pool.with_connection do
              queue << [ provider, search_provider(provider, query, limit: limit, content_kind: content_kind) ]
            end
          end
        rescue StandardError => e
          Rails.logger.warn "[MetadataService] #{provider} search failed: #{e.message}"
          queue << [ provider, [] ]
        end
      end

      providers.size.times do
        provider, results = queue.pop
        results_by_provider[provider] = results
      end
      threads.each(&:join)
      results_by_provider
    end

    def ordered_provider_results(results_by_provider)
      priority = provider_priority
      priority.flat_map { |provider| results_by_provider[provider] || [] } +
        results_by_provider.except(*priority).values.flatten
    end

    def sort_candidates(candidates, requested_content_kind: nil)
      priority = provider_priority
      candidates.sort_by do |candidate|
        [
          candidate.content_kind == requested_content_kind ? 0 : 1,
          priority.index(candidate.source.to_s) || priority.size,
          -candidate.confidence,
          candidate.title.to_s.downcase,
          candidate.canonical_key.to_s
        ]
      end
    end

    def provider_limit(provider, requested_limit)
      return requested_limit if requested_limit.present?

      case provider.to_s
      when "hardcover"
        SettingsService.get(:hardcover_search_limit, default: 10)
      when "google_books"
        SettingsService.get(:google_books_search_limit, default: 20)
      when "openlibrary"
        SettingsService.get(:open_library_search_limit, default: 20)
      when "comic_vine"
        SettingsService.get(:comic_vine_search_limit, default: 10)
      else
        default_search_limit
      end
    end

    def filter_candidates_for_content(candidates, requested_content_kind)
      return candidates unless requested_content_kind

      candidates.select do |candidate|
        candidate.content_kind == requested_content_kind ||
          candidate.classification_confidence < MetadataSearch::ContentClassifier::STRONG_CONFIDENCE
      end
    end

    def default_search_limit
      20
    end

    def fetch_hardcover_details(id)
      details = HardcoverClient.book(id)
      normalize_hardcover_details(details)
    end

    def fetch_openlibrary_details(work_id)
      work = OpenLibraryClient.work(work_id)
      normalize_openlibrary_work(work)
    end

    def fetch_google_books_details(id)
      details = GoogleBooksClient.book(id)
      normalize_google_books_details(details)
    end

    def normalize_hardcover_details(details)
      SearchResult.new(
        source: "hardcover",
        source_id: details.id.to_s,
        title: details.title,
        author: details.author,
        description: details.description,
        year: details.release_year,
        cover_url: details.cover_url,
        has_audiobook: details.has_audiobook,
        has_ebook: details.has_ebook,
        series_name: details.series_name,
        series_position: details.series_position
      )
    end

    def normalize_openlibrary_work(work)
      SearchResult.new(
        source: "openlibrary",
        source_id: work.work_id,
        title: work.title,
        author: nil, # Work doesn't include author
        description: work.description,
        year: parse_year(work.first_publish_date),
        cover_url: work.cover_url(size: :l),
        has_audiobook: nil,
        has_ebook: nil,
        series_name: nil,
        series_position: nil
      )
    end

    def normalize_google_books_details(details)
      SearchResult.new(
        source: "google_books",
        source_id: details.id,
        title: details.title,
        author: details.author,
        description: details.description,
        year: details.release_year,
        cover_url: details.cover_url,
        has_audiobook: nil,
        has_ebook: details.has_ebook,
        series_name: nil,
        series_position: nil
      )
    end

    def parse_work_id(work_id)
      Book.parse_work_id(work_id)
    end

    def parse_year(date_string)
      return nil if date_string.blank?
      match = date_string.to_s.match(/\b(1[89]\d{2}|20[0-2]\d)\b/)
      match ? match[1].to_i : nil
    end

    def truncate_description(desc)
      return nil if desc.blank?
      desc.length > 500 ? "#{desc[0, 497]}..." : desc
    end
  end
end
