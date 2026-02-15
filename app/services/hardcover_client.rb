# frozen_string_literal: true

# Client for interacting with the Hardcover GraphQL API
# https://hardcover.app/account/api
class HardcoverClient
  BASE_URL = "https://api.hardcover.app/v1/graphql"

  # Custom error classes
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class NotFoundError < Error; end
  class NotConfiguredError < Error; end

  # Data structures for API responses
  SearchResult = Data.define(
    :id, :title, :author, :description, :release_year,
    :cover_url, :has_audiobook, :has_ebook
  ) do
    def work_id
      "hardcover:#{id}"
    end

    # Compatibility with OpenLibrary patterns
    def first_publish_year
      release_year
    end

    def cover_id
      nil # Hardcover provides full URLs
    end
  end

  BookDetails = Data.define(
    :id, :title, :author, :description, :release_year,
    :cover_url, :has_audiobook, :has_ebook, :pages, :genres, :series_name
  ) do
    def work_id
      "hardcover:#{id}"
    end
  end

  class << self
    def configured?
      SettingsService.hardcover_configured?
    end

    # Search for books by query
    # Returns array of SearchResult
    def search(query, limit: nil)
      ensure_configured!
      limit ||= SettingsService.get(:hardcover_search_limit, default: 10)

      query_string = <<~GRAPHQL
        query SearchBooks($query: String!, $perPage: Int!) {
          search(query: $query, query_type: "Book", per_page: $perPage) {
            results
          }
        }
      GRAPHQL

      response = execute_query(query_string, { query: query, perPage: limit })

      # Debug: log full response structure to understand format
      Rails.logger.info "[HardcoverClient] Response keys: #{response.keys rescue 'not a hash'}"
      Rails.logger.info "[HardcoverClient] Search data: #{response.dig('data', 'search')&.keys rescue 'not accessible'}"

      raw_results = response.dig("data", "search", "results")
      results = extract_hits(raw_results)

      Rails.logger.info "[HardcoverClient] Search '#{query}' returned #{results.size} results"
      if results.any?
        Rails.logger.info "[HardcoverClient] First result class: #{results.first.class}"
        Rails.logger.info "[HardcoverClient] First result: #{results.first.inspect[0..500]}"
      end

      results.filter_map { |result| parse_search_result(result) }
    end

    # Get book details by Hardcover book ID
    # Returns BookDetails
    def book(book_id)
      ensure_configured!

      query_string = <<~GRAPHQL
        query GetBook($id: Int!) {
          books(where: { id: { _eq: $id } }) {
            id
            title
            description
            release_year
            cached_image
            contributions {
              author {
                name
              }
            }
            default_physical_edition {
              pages
            }
            book_series {
              series {
                name
              }
            }
          }
        }
      GRAPHQL

      response = execute_query(query_string, { id: book_id.to_i })
      books = response.dig("data", "books") || []

      raise NotFoundError, "Book not found: #{book_id}" if books.empty?

      parse_book_details(books.first)
    end

    # Test API connection
    def test_connection
      ensure_configured!

      # Simple query to verify authentication
      query_string = <<~GRAPHQL
        query TestConnection {
          me {
            id
          }
        }
      GRAPHQL

      response = execute_query(query_string, {})

      # Check if we got a valid response with data
      # API returns me as an array: {"data"=>{"me"=>[{"id"=>69591}]}}
      data = response["data"] if response.is_a?(Hash)
      me = data["me"] if data.is_a?(Hash)
      me = me.first if me.is_a?(Array)
      result = me.is_a?(Hash) && me["id"].present?

      Rails.logger.info "[HardcoverClient] Connection test: #{result ? 'passed' : 'failed'}"
      result
    rescue Error => e
      Rails.logger.error "[HardcoverClient] Connection test failed: #{e.message}"
      false
    end

    def reset_connection!
      @connection = nil
    end

    private

    def ensure_configured!
      raise NotConfiguredError, "Hardcover API token not configured" unless configured?
    end

    def execute_query(query, variables)
      response = connection.post do |req|
        req.body = { query: query, variables: variables }.to_json
      end

      handle_response(response)
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      Rails.logger.error "[HardcoverClient] Connection error: #{e.message}"
      raise ConnectionError, "Failed to connect to Hardcover: #{e.message}"
    end

    def connection
      @connection ||= Faraday.new(url: BASE_URL) do |f|
        f.request :json
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.headers["Content-Type"] = "application/json"
        f.headers["authorization"] = api_token
        f.headers["User-Agent"] = "Shelfarr/1.0"
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end

    def api_token
      SettingsService.get(:hardcover_api_token)
    end

    def handle_response(response)
      case response.status
      when 200
        body = response.body
        if body["errors"]&.any?
          error_message = body["errors"].map { |e| e["message"] }.join(", ")
          Rails.logger.error "[HardcoverClient] GraphQL error: #{error_message}"
          raise Error, "GraphQL error: #{error_message}"
        end
        body
      when 401, 403
        Rails.logger.error "[HardcoverClient] Authentication failed (status #{response.status})"
        raise AuthenticationError, "Invalid API token"
      when 429
        Rails.logger.warn "[HardcoverClient] Rate limit exceeded"
        raise RateLimitError, "Rate limit exceeded (60 requests/minute)"
      else
        Rails.logger.error "[HardcoverClient] API error (status #{response.status})"
        raise Error, "API request failed with status #{response.status}"
      end
    end

    def parse_search_result(result)
      doc = result["document"]
      return nil unless doc.is_a?(Hash)

      SearchResult.new(
        id: doc["id"]&.to_s,
        title: doc["title"],
        author: extract_author(doc),
        description: doc["description"],
        release_year: doc["release_year"],
        cover_url: extract_cover_url(doc),
        has_audiobook: doc["has_audiobook"] || false,
        has_ebook: doc["has_ebook"] || false
      )
    end

    def extract_author(doc)
      doc["author_names"]&.first || doc["author"]
    end

    def parse_book_details(book)
      # Extract author from contributions
      author = book.dig("contributions", 0, "author", "name")

      # Extract series name
      series_name = book.dig("book_series", 0, "series", "name")

      # Extract pages from default edition
      pages = book.dig("default_physical_edition", "pages")

      BookDetails.new(
        id: book["id"].to_s,
        title: book["title"],
        author: author,
        description: book["description"],
        release_year: book["release_year"],
        cover_url: extract_cover_url(book),
        has_audiobook: false, # Not available in this query
        has_ebook: false,     # Not available in this query
        pages: pages,
        genres: [],           # Would need separate query
        series_name: series_name
      )
    end

    def extract_cover_url(doc)
      cached = doc["cached_image"]
      image = doc["image"]
      
      cached_url = cached.is_a?(Hash) ? cached["url"] : cached
      image_url = image.is_a?(Hash) ? image["url"] : image
      
      cached_url || image_url
    end

    def extract_hits(raw_results)
      return [] unless raw_results.is_a?(Hash)
      
      hits = raw_results["hits"]
      hits.is_a?(Array) ? hits : []
    end
  end
end
