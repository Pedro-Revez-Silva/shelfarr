# frozen_string_literal: true

# Client for BookOrbit's current internal API. BookOrbit does not publish stable
# API docs yet, so this intentionally covers only library inventory and scans.
class BookOrbitClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthenticationError < Error; end
  class NotConfiguredError < Error; end

  Library = Data.define(:id, :name, :folders, :media_type) do
    def folder_paths
      folders.map { |folder| folder["fullPath"] || folder["path"] }.compact
    end

    def audiobook_library?
      true
    end

    def podcast_library?
      false
    end
  end

  class << self
    def libraries
      ensure_configured!

      response = request { connection.get("/api/v1/libraries") }
      handle_response(response) do |data|
        Array(data).map { |library| parse_library(library) }
      end
    end

    def library(id)
      ensure_configured!

      response = request { connection.get("/api/v1/libraries/#{id}") }
      handle_response(response) { |data| parse_library(data) }
    end

    def scan_library(id)
      ensure_configured!

      response = request { connection.post("/api/v1/scanner/libraries/#{id}/scan") }
      response.status.in?([ 200, 201, 202, 204 ])
    end

    def library_items(id, page_size: 200)
      ensure_configured!

      items = []
      page = 0
      query_page_size = [ page_size.to_i, 200 ].min
      query_page_size = 200 if query_page_size <= 0

      loop do
        response = request do
          connection.post("/api/v1/libraries/#{id}/books", {
            sort: [],
            pagination: { page: page, size: query_page_size },
            collapseSeries: false
          })
        end
        break unless response.status == 200

        page_items = extract_library_items(response.body)
        items.concat(page_items)
        break if end_of_items?(page_items, response.body, query_page_size, page)
        page += 1
      end

      items
    end

    def delete_item_by_path(_path)
      false
    end

    def configured?
      SettingsService.bookorbit_configured?
    end

    def test_connection
      ensure_configured!
      libraries.any?
    rescue Error
      false
    end

    def reset_connection!
      @connection = nil
      @access_token = nil
    end

    private

    def ensure_configured!
      raise NotConfiguredError, "BookOrbit is not configured" unless configured?
    end

    def request
      yield
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError, URI::Error => e
      raise ConnectionError, "Failed to connect to BookOrbit: #{e.message}"
    end

    def connection
      @connection ||= Faraday.new(url: base_url) do |f|
        f.request :json
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.headers["Authorization"] = "Bearer #{access_token}"
        f.options.timeout = 15
        f.options.open_timeout = 5
      end
    end

    def auth_connection
      Faraday.new(url: base_url) do |f|
        f.request :json
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.options.timeout = 15
        f.options.open_timeout = 5
      end
    end

    def access_token
      @access_token ||= begin
        response = request do
          auth_connection.post("/api/v1/auth/login", {
            username: SettingsService.get(:bookorbit_username),
            password: SettingsService.get(:bookorbit_password)
          })
        end
        handle_response(response) do |data|
          token = data["accessToken"]
          raise AuthenticationError, "BookOrbit login did not return an access token" if token.blank?

          token
        end
      end
    end

    def base_url
      url = SettingsService.get(:bookorbit_url).to_s.strip
      parsed_url = URI.parse(url)

      unless parsed_url.is_a?(URI::HTTP) && parsed_url.host.present?
        raise URI::InvalidURIError, "BookOrbit URL must include http:// or https://"
      end

      url
    end

    def handle_response(response)
      case response.status
      when 200, 201, 202, 204
        yield(response.body.presence || {})
      when 401, 403
        raise AuthenticationError, "Invalid BookOrbit credentials or permissions"
      when 404
        raise Error, "BookOrbit resource not found"
      else
        raise Error, "BookOrbit API error: #{response.status}"
      end
    end

    def parse_library(data)
      Library.new(
        id: data["id"].to_s,
        name: data["name"],
        folders: data["folders"] || [],
        media_type: "bookorbit"
      )
    end

    def extract_library_items(data)
      Array(data["items"]).filter_map do |raw_item|
        next unless raw_item.is_a?(Hash)

        {
          "audiobookshelf_id" => raw_item["id"].to_s,
          "title" => raw_item["title"],
          "subtitle" => raw_item["subtitle"],
          "author" => Array(raw_item["authors"]).join(", ").presence,
          "narrator" => Array(raw_item["narrators"]).join(", ").presence,
          "series" => raw_item["seriesName"],
          "series_position" => raw_item["seriesIndex"]&.to_s,
          "publisher" => raw_item["publisher"],
          "language" => raw_item["language"],
          "description" => nil,
          "isbn" => raw_item["isbn13"],
          "asin" => nil,
          "published_year" => raw_item["publishedYear"],
          "missing" => raw_item["status"] == "missing"
        }
      end
    end

    def end_of_items?(page_items, data, page_size, page)
      return true if page_items.empty?
      return true if page_items.length < page_size

      total = data["total"]
      total.present? && total <= ((page + 1) * page_size)
    end
  end
end
