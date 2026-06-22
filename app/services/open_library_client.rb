# frozen_string_literal: true

# Client for interacting with the Open Library API
# https://openlibrary.org/developers/api
class OpenLibraryClient
  BASE_URL = "https://openlibrary.org"
  COVERS_URL = "https://covers.openlibrary.org"

  # Custom error classes
  class Error < StandardError; end
  class ConnectionError < Error; end
  class NotFoundError < Error; end
  class RateLimitError < Error; end

  # Data structures for API responses
  SearchResult = Data.define(:work_id, :title, :author, :first_publish_year, :cover_id, :edition_count) do
    def cover_url(size: :m)
      return nil unless cover_id
      OpenLibraryClient.cover_url(cover_id, size: size)
    end
  end

  WorkDetails = Data.define(
    :work_id, :title, :description, :subjects, :covers, :first_publish_date
  ) do
    def cover_url(size: :m)
      return nil if covers.blank?
      OpenLibraryClient.cover_url(covers.first, size: size)
    end
  end

  EditionDetails = Data.define(
    :edition_id, :work_id, :title, :authors, :publishers, :publish_date,
    :isbn_10, :isbn_13, :covers, :number_of_pages, :languages
  ) do
    def cover_url(size: :m)
      return nil if covers.blank?
      OpenLibraryClient.cover_url(covers.first, size: size)
    end

    def isbn
      isbn_13&.first || isbn_10&.first
    end

    def language
      languages&.first&.dig("key")&.split("/")&.last
    end
  end

  class << self
    def configured?
      SettingsService.get(:open_library_enabled, default: true)
    end

    # Search for books by query
    # Returns array of SearchResult
    def search(query, limit: nil)
      limit ||= SettingsService.get("open_library_search_limit", default: 20)

      response = connection.get("/search.json", {
        q: query,
        limit: limit,
        fields: "key,title,author_name,first_publish_year,cover_i,edition_count"
      })

      handle_response(response) do |data|
        (data["docs"] || []).map do |doc|
          SearchResult.new(
            work_id: extract_work_id(doc["key"]),
            title: doc["title"],
            author: Array(doc["author_name"]).first,
            first_publish_year: doc["first_publish_year"],
            cover_id: doc["cover_i"],
            edition_count: doc["edition_count"]
          )
        end
      end
    end

    # Get work details by work ID (e.g., "OL45804W")
    # Returns WorkDetails
    def work(work_id)
      work_id = normalize_work_id(work_id)
      response = connection.get("/works/#{work_id}.json")

      handle_response(response) do |data|
        WorkDetails.new(
          work_id: work_id,
          title: data["title"],
          description: extract_description(data["description"]),
          subjects: data["subjects"] || [],
          covers: data["covers"] || [],
          first_publish_date: data["first_publish_date"]
        )
      end
    end

    # Get edition details by edition ID (e.g., "OL7353617M")
    # Returns EditionDetails
    def edition(edition_id)
      edition_id = normalize_edition_id(edition_id)
      response = connection.get("/books/#{edition_id}.json")

      handle_response(response) do |data|
        work_key = data.dig("works", 0, "key")

        EditionDetails.new(
          edition_id: edition_id,
          work_id: work_key ? extract_work_id(work_key) : nil,
          title: data["title"],
          authors: extract_author_names(data["authors"]),
          publishers: data["publishers"] || [],
          publish_date: data["publish_date"],
          isbn_10: data["isbn_10"],
          isbn_13: data["isbn_13"],
          covers: data["covers"] || [],
          number_of_pages: data["number_of_pages"],
          languages: data["languages"]
        )
      end
    end

    # Get editions for a work
    # Returns array of EditionDetails
    def work_editions(work_id, limit: 10)
      work_id = normalize_work_id(work_id)
      response = connection.get("/works/#{work_id}/editions.json", { limit: limit })

      handle_response(response) do |data|
        (data["entries"] || []).map do |entry|
          EditionDetails.new(
            edition_id: extract_edition_id(entry["key"]),
            work_id: work_id,
            title: entry["title"],
            authors: extract_author_names(entry["authors"]),
            publishers: entry["publishers"] || [],
            publish_date: entry["publish_date"],
            isbn_10: entry["isbn_10"],
            isbn_13: entry["isbn_13"],
            covers: entry["covers"] || [],
            number_of_pages: entry["number_of_pages"],
            languages: entry["languages"]
          )
        end
      end
    end

    def test_connection
      return false unless configured?

      search("test", limit: 1)
      true
    rescue Error => e
      Rails.logger.error "[OpenLibraryClient] Connection test failed: #{e.message}"
      false
    end

    def reset_connection!
      @connection = nil
    end

    # Generate cover image URL
    # size: :s (small), :m (medium), :l (large)
    def cover_url(cover_id, size: :m)
      return nil if cover_id.blank?
      "#{COVERS_URL}/b/id/#{cover_id}-#{size.to_s.upcase}.jpg"
    end

    private

    def connection
      @connection ||= Faraday.new(url: BASE_URL) do |f|
        f.request :url_encoded
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.options.timeout = 15
        f.options.open_timeout = 5
      end
    end

    def handle_response(response)
      case response.status
      when 200
        yield response.body
      when 404
        raise NotFoundError, "Resource not found"
      when 429
        raise RateLimitError, "Rate limit exceeded"
      else
        raise Error, "API request failed with status #{response.status}"
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise ConnectionError, "Failed to connect to Open Library: #{e.message}"
    end

    def extract_work_id(key)
      return nil if key.blank?
      key.to_s.split("/").last
    end

    def extract_edition_id(key)
      return nil if key.blank?
      key.to_s.split("/").last
    end

    def normalize_work_id(work_id)
      work_id.to_s.gsub(%r{^/works/}, "")
    end

    def normalize_edition_id(edition_id)
      edition_id.to_s.gsub(%r{^/books/}, "")
    end

    def extract_description(desc)
      return nil if desc.blank?
      desc.is_a?(Hash) ? desc["value"] : desc.to_s
    end

    def extract_author_names(authors)
      return [] if authors.blank?

      authors.filter_map do |author|
        if author.is_a?(Hash) && author["key"]
          # Would need another API call to resolve, skip for now
          nil
        else
          author.to_s
        end
      end
    end
  end
end
