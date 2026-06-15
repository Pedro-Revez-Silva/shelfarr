# frozen_string_literal: true

# Client for interacting with the Google Books API
# https://developers.google.com/books/docs/v1/using
class GoogleBooksClient
  BASE_URL = "https://www.googleapis.com/books/v1"

  # Custom error classes
  class Error < StandardError; end
  class ConnectionError < Error; end
  class NotFoundError < Error; end
  class RateLimitError < Error; end

  SearchResult = Data.define(
    :id, :title, :author, :description, :year, :cover_url, :has_ebook
  ) do
    def work_id
      "googlebooks:#{id}"
    end

    # Compatibility with OpenLibrary patterns
    def first_publish_year
      year
    end

    def cover_id
      nil
    end
  end

  VolumeDetails = Data.define(
    :id, :title, :author, :description, :year, :cover_url, :has_ebook, :pages
  ) do
    def work_id
      "googlebooks:#{id}"
    end
  end

  class << self
    # Google Books requires an API key to be enabled.
    def configured?
      SettingsService.get(:google_books_api_key).present?
    end

    # Search for books by query. Returns array of SearchResult.
    def search(query, limit: nil)
      limit ||= SettingsService.get(:google_books_search_limit, default: 20)

      response = connection.get("volumes", build_params(q: query, maxResults: limit))

      handle_response(response) do |data|
        Array(data["items"]).map { |item| parse_search_result(item) }
      end
    end

    # Get volume details by Google volume id. Returns VolumeDetails.
    def volume(volume_id)
      response = connection.get("volumes/#{volume_id}", build_params)

      handle_response(response) do |data|
        parse_volume_details(data)
      end
    end

    # Test API reachability with a minimal query.
    def test_connection
      return false unless configured?

      search("ruby", limit: 1)
      true
    rescue Error => e
      Rails.logger.error "[GoogleBooksClient] Connection test failed: #{e.message}"
      false
    end

    private

    def build_params(extra = {})
      params = extra.dup
      key = SettingsService.get(:google_books_api_key)
      params[:key] = key if key.present?
      params
    end

    def connection
      @connection ||= Faraday.new(url: "#{BASE_URL}/") do |f|
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
      raise ConnectionError, "Failed to connect to Google Books: #{e.message}"
    end

    def parse_search_result(item)
      info = item["volumeInfo"] || {}
      access = item["accessInfo"] || {}

      SearchResult.new(
        id: item["id"],
        title: info["title"],
        author: Array(info["authors"]).first,
        description: info["description"],
        year: parse_year(info["publishedDate"]),
        cover_url: extract_cover_url(info["imageLinks"]),
        has_ebook: access.dig("epub", "isAvailable") || false
      )
    end

    def parse_volume_details(item)
      info = item["volumeInfo"] || {}
      access = item["accessInfo"] || {}

      VolumeDetails.new(
        id: item["id"],
        title: info["title"],
        author: Array(info["authors"]).first,
        description: info["description"],
        year: parse_year(info["publishedDate"]),
        cover_url: extract_cover_url(info["imageLinks"]),
        has_ebook: access.dig("epub", "isAvailable") || false,
        pages: info["pageCount"]
      )
    end

    def extract_cover_url(image_links)
      return nil if image_links.blank?

      url = image_links["thumbnail"] || image_links["smallThumbnail"]
      return nil if url.blank?

      url.sub("http://", "https://").sub("&edge=curl", "")
    end

    def parse_year(date_string)
      return nil if date_string.blank?

      match = date_string.to_s.match(/\b(1[0-9]{3}|20[0-9]{2})\b/)
      match ? match[1].to_i : nil
    end
  end
end
