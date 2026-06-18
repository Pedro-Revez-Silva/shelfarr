# frozen_string_literal: true

# Unified service for fetching book metadata from configured sources
# Orchestrates Hardcover, Google Books, and OpenLibrary based on settings
class MetadataService
  class Error < StandardError; end

  # Unified result structure compatible with both sources
  SearchResult = Data.define(
    :source, :source_id, :title, :author, :description, :year,
    :cover_url, :has_audiobook, :has_ebook, :series_name, :series_position
  ) do
    SOURCE_NAMES = {
      "hardcover" => "Hardcover",
      "google_books" => "Google Books",
      "openlibrary" => "Open Library"
    }.freeze

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
      SOURCE_NAMES.fetch(source.to_s, source.to_s.titleize)
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
    # Search for books across configured metadata sources
    # Returns array of SearchResult
    def search(query, limit: nil)
      source = metadata_source

      Rails.logger.info "[MetadataService] Searching '#{query}' using source: #{source}"

      case source
      when "hardcover"
        search_hardcover(query, limit)
      when "google_books"
        search_google_books(query, limit)
      when "openlibrary"
        search_openlibrary(query, limit)
      else # "auto"
        search_with_fallback(query, limit)
      end
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

      results[:google_books] = GoogleBooksClient.test_connection rescue false

      # OpenLibrary doesn't require configuration
      results[:openlibrary] = begin
        OpenLibraryClient.search("test", limit: 1)
        true
      rescue
        false
      end

      results
    end

    # Determine primary metadata source
    def metadata_source
      SettingsService.get(:metadata_source, default: "auto")
    end

    # Check if any metadata source is available
    def available?
      metadata_source == "openlibrary" ||
        metadata_source == "google_books" ||
        (metadata_source == "hardcover" && HardcoverClient.configured?) ||
        (metadata_source == "auto") # OpenLibrary and Google Books are always available as fallbacks
    end

    private

    def search_hardcover(query, limit)
      return [] unless HardcoverClient.configured?

      results = HardcoverClient.search(query, limit: limit)
      results.map { |r| normalize_hardcover_result(r) }
    rescue HardcoverClient::Error => e
      Rails.logger.error "[MetadataService] Hardcover search failed: #{e.message}"
      []
    end

    def search_openlibrary(query, limit)
      results = OpenLibraryClient.search(query, limit: limit)
      results.map { |r| normalize_openlibrary_result(r) }
    rescue OpenLibraryClient::Error => e
      Rails.logger.error "[MetadataService] OpenLibrary search failed: #{e.message}"
      []
    end

    def search_google_books(query, limit)
      results = GoogleBooksClient.search(query, limit: limit)
      results.map { |r| normalize_google_books_result(r) }
    rescue GoogleBooksClient::Error => e
      Rails.logger.error "[MetadataService] Google Books search failed: #{e.message}"
      []
    end

    def search_with_fallback(query, limit)
      # Try Hardcover first if configured
      if HardcoverClient.configured?
        results = search_hardcover(query, limit)
        if results.any?
          Rails.logger.info "[MetadataService] Found #{results.size} results from Hardcover"
          return results
        end

        Rails.logger.info "[MetadataService] No Hardcover results, falling back to OpenLibrary"
      end

      # Keep OpenLibrary ahead of Google Books to preserve existing work-id matching.
      results = search_openlibrary(query, limit)
      if results.any?
        Rails.logger.info "[MetadataService] Found #{results.size} results from OpenLibrary"
        return results
      end

      Rails.logger.info "[MetadataService] No OpenLibrary results, falling back to Google Books"

      results = search_google_books(query, limit)
      Rails.logger.info "[MetadataService] Found #{results.size} results from Google Books"
      results
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

    def normalize_hardcover_result(result)
      SearchResult.new(
        source: "hardcover",
        source_id: result.id.to_s,
        title: result.title,
        author: result.author,
        description: truncate_description(result.description),
        year: result.release_year,
        cover_url: result.cover_url,
        has_audiobook: result.has_audiobook,
        has_ebook: result.has_ebook,
        series_name: result.series_name,
        series_position: result.series_position
      )
    end

    def normalize_openlibrary_result(result)
      SearchResult.new(
        source: "openlibrary",
        source_id: result.work_id,
        title: result.title,
        author: result.author,
        description: nil, # OpenLibrary search doesn't return description
        year: result.first_publish_year,
        cover_url: result.cover_url(size: :l),
        has_audiobook: nil, # Unknown from OpenLibrary
        has_ebook: nil,
        series_name: nil,
        series_position: nil
      )
    end

    def normalize_google_books_result(result)
      SearchResult.new(
        source: "google_books",
        source_id: result.id,
        title: result.title,
        author: result.author,
        description: truncate_description(result.description),
        year: result.first_publish_year,
        cover_url: result.cover_url,
        has_audiobook: nil,
        has_ebook: result.has_ebook,
        series_name: nil,
        series_position: nil
      )
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
