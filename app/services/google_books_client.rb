# frozen_string_literal: true

# Client for interacting with the Google Books Volumes API
# https://developers.google.com/books/docs/v1/using
class GoogleBooksClient
  BASE_URL = "https://www.googleapis.com"
  MAX_RESULTS = 40

  class Error < StandardError; end
  class ConnectionError < Error; end
  class NotFoundError < Error; end
  class RateLimitError < Error; end

  SearchResult = Data.define(
    :id, :title, :author, :description, :published_date,
    :cover_url, :has_ebook, :language
  ) do
    def work_id
      "google_books:#{id}"
    end

    def first_publish_year
      GoogleBooksClient.parse_year(published_date)
    end

    def cover_id
      nil
    end
  end

  BookDetails = Data.define(
    :id, :title, :author, :description, :published_date,
    :cover_url, :has_ebook, :language, :page_count, :categories
  ) do
    def work_id
      "google_books:#{id}"
    end

    def release_year
      GoogleBooksClient.parse_year(published_date)
    end
  end

  class << self
    def configured?
      true
    end

    def search(query, limit: nil)
      limit = normalize_limit(limit || SettingsService.get(:google_books_search_limit, default: 20))

      response = connection.get("/books/v1/volumes", {
        q: query,
        maxResults: limit,
        printType: "books"
      }.merge(api_key_param))

      handle_response(response) do |data|
        Array(data["items"]).filter_map { |item| parse_search_result(item) }
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise ConnectionError, "Failed to connect to Google Books: #{e.message}"
    end

    def book(volume_id)
      response = connection.get("/books/v1/volumes/#{volume_id}", api_key_param)

      handle_response(response) do |data|
        parse_book_details(data)
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise ConnectionError, "Failed to connect to Google Books: #{e.message}"
    end

    def test_connection
      search("test", limit: 1)
      true
    rescue Error => e
      Rails.logger.error "[GoogleBooksClient] Connection test failed: #{e.message}"
      false
    end

    def reset_connection!
      @connection = nil
    end

    def parse_year(date_string)
      return nil if date_string.blank?

      match = date_string.to_s.match(/\b(1[89]\d{2}|20[0-2]\d)\b/)
      match ? match[1].to_i : nil
    end

    private

    def connection
      @connection ||= Faraday.new(url: BASE_URL) do |f|
        f.request :url_encoded
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.headers["User-Agent"] = "Shelfarr/1.0"
        f.options.timeout = 15
        f.options.open_timeout = 5
      end
    end

    def handle_response(response)
      case response.status
      when 200
        yield response.body
      when 404
        raise NotFoundError, "Volume not found"
      when 403, 429
        raise RateLimitError, "Rate limit exceeded"
      else
        raise Error, "API request failed with status #{response.status}"
      end
    end

    def api_key_param
      key = SettingsService.get(:google_books_api_key).to_s.strip
      key.present? ? { key: key } : {}
    end

    def parse_search_result(item)
      volume = item["volumeInfo"] || {}
      return nil if item["id"].blank? || volume["title"].blank?

      SearchResult.new(
        id: item["id"].to_s,
        title: volume["title"],
        author: Array(volume["authors"]).first,
        description: volume["description"],
        published_date: volume["publishedDate"],
        cover_url: extract_cover_url(volume),
        has_ebook: ebook_available?(item),
        language: volume["language"]
      )
    end

    def parse_book_details(item)
      volume = item["volumeInfo"] || {}
      raise NotFoundError, "Volume not found" if item["id"].blank? || volume.blank?

      BookDetails.new(
        id: item["id"].to_s,
        title: volume["title"],
        author: Array(volume["authors"]).first,
        description: volume["description"],
        published_date: volume["publishedDate"],
        cover_url: extract_cover_url(volume),
        has_ebook: ebook_available?(item),
        language: volume["language"],
        page_count: volume["pageCount"],
        categories: Array(volume["categories"])
      )
    end

    def extract_cover_url(volume)
      links = volume["imageLinks"] || {}
      url = links["extraLarge"] || links["large"] || links["medium"] || links["thumbnail"] || links["smallThumbnail"]
      url&.sub(/^http:/, "https:")
    end

    def ebook_available?(item)
      sale_info = item["saleInfo"] || {}
      access_info = item["accessInfo"] || {}

      sale_info["isEbook"] == true ||
        access_info.dig("epub", "isAvailable") == true ||
        access_info.dig("pdf", "isAvailable") == true
    end

    def normalize_limit(limit)
      limit.to_i.clamp(1, MAX_RESULTS)
    end
  end
end
