# frozen_string_literal: true

# Unified service for fetching book metadata from configured sources
# Orchestrates Hardcover (primary) and OpenLibrary (fallback) based on settings
class MetadataService
  class Error < StandardError; end

  # Unified result structure compatible with both sources
  SearchResult = Data.define(
    :source, :source_id, :title, :author, :description, :year,
    :cover_url, :has_audiobook, :has_ebook, :series_name
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
  end

  class << self
    # Search for books across configured metadata sources
    # Returns array of SearchResult
    def search(query, limit: 10)
      source = metadata_source

      Rails.logger.info "[MetadataService] Searching '#{query}' using source: #{source}"

      case source
      when "hardcover"
        search_hardcover(query, limit)
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
        (metadata_source == "hardcover" && HardcoverClient.configured?) ||
        (metadata_source == "auto") # OpenLibrary always available as fallback
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

      # Fallback to OpenLibrary
      results = search_openlibrary(query, limit)
      Rails.logger.info "[MetadataService] Found #{results.size} results from OpenLibrary"
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
        series_name: nil
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
        series_name: nil
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
        series_name: details.series_name
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
        series_name: nil
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
