# frozen_string_literal: true

# Client for BookOrbit's current internal API. BookOrbit does not publish stable
# API docs yet, so this intentionally covers only library inventory and scans.
class BookOrbitClient
  CONNECTION_MUTEX = Mutex.new

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

      response = authenticated_request { |client| client.get("/api/v1/libraries") }
      handle_response(response) do |data|
        Array(data).map { |library| parse_library(library) }
      end
    end

    def library(id)
      ensure_configured!

      response = authenticated_request { |client| client.get("/api/v1/libraries/#{id}") }
      handle_response(response) { |data| parse_library(data) }
    end

    def scan_library(id)
      ensure_configured!

      response = authenticated_request { |client| client.post("/api/v1/scanner/libraries/#{id}/scan") }
      handle_response(response, success_statuses: [ 202 ]) { true }
    end

    def library_items(id, page_size: 200)
      ensure_configured!

      query_page_size = [ page_size.to_i, 200 ].min
      query_page_size = 200 if query_page_size <= 0
      items = fetch_library_items(id, query_page_size)
      return items if items.size <= query_page_size

      verified_items = fetch_library_items(id, query_page_size)
      if items.pluck("audiobookshelf_id").sort != verified_items.pluck("audiobookshelf_id").sort
        raise Error, "BookOrbit library inventory changed during synchronization"
      end

      verified_items
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
      CONNECTION_MUTEX.synchronize { clear_connection_cache! }
    end

    private

    def fetch_library_items(id, page_size)
      items = []
      item_ids = {}
      expected_total = nil
      page = 0

      loop do
        response = authenticated_request do |client|
          client.post("/api/v1/libraries/#{id}/books", {
            sort: [],
            pagination: { page: page, size: page_size },
            collapseSeries: false
          })
        end
        if (response.status == 404 || response.status == 410) && page == 0
          return []
        end

        data = handle_response(response, success_statuses: [ 200, 201 ]) { |body| body }
        page_items, total = extract_library_items(data, page: page, page_size: page_size)
        expected_total ||= total
        if total != expected_total
          raise Error, "BookOrbit library inventory changed during synchronization"
        end

        page_items.each do |item|
          item_id = item["audiobookshelf_id"]
          raise Error, "BookOrbit library inventory changed during synchronization" if item_ids.key?(item_id)

          item_ids[item_id] = true
        end
        items.concat(page_items)
        break if items.size >= expected_total
        if page_items.size < page_size
          raise Error, "BookOrbit returned an incomplete library inventory"
        end
        page += 1
      end

      items
    end

    def ensure_configured!
      raise NotConfiguredError, "BookOrbit is not configured" unless configured?
    end

    def request
      yield
    rescue Faraday::ParsingError
      raise Error, "BookOrbit returned invalid JSON"
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError, URI::Error => e
      raise ConnectionError, "Failed to connect to BookOrbit: #{e.message}"
    end

    def authenticated_request
      request_connection = request { connection }
      response = request { yield(request_connection) }
      return response unless response.status.in?([ 401, 403 ])

      CONNECTION_MUTEX.synchronize do
        clear_connection_cache! if @connection.equal?(request_connection)
      end
      request { yield(connection) }
    end

    def connection
      CONNECTION_MUTEX.synchronize do
        configuration = current_connection_configuration
        rebuild_connection!(configuration) if @connection.nil? || @connection_configuration != configuration
        @connection
      end
    end

    def build_connection(configuration)
      Faraday.new(url: validated_base_url(configuration)) do |f|
        f.request :json
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.headers["Authorization"] = "Bearer #{access_token(configuration)}"
        f.options.timeout = 15
        f.options.open_timeout = 5
      end
    end

    def auth_connection(configuration)
      Faraday.new(url: validated_base_url(configuration)) do |f|
        f.request :json
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.options.timeout = 15
        f.options.open_timeout = 5
      end
    end

    def access_token(configuration)
      @access_token ||= begin
        response = request do
          auth_connection(configuration).post("/api/v1/auth/login", {
            username: configuration.fetch(1),
            password: configuration.fetch(2)
          })
        end
        handle_response(response) do |data|
          token = data["accessToken"]
          raise AuthenticationError, "BookOrbit login did not return an access token" if token.blank?

          token
        end
      end
    end

    def clear_connection_cache!
      @connection = nil
      @access_token = nil
      @connection_configuration = nil
    end

    def rebuild_connection!(configuration)
      clear_connection_cache!
      connection = build_connection(configuration)
      @connection = connection
      @connection_configuration = configuration
    end

    def current_connection_configuration
      configuration = [
        SettingsService.get(:bookorbit_url).to_s.strip,
        SettingsService.get(:bookorbit_username).to_s,
        SettingsService.get(:bookorbit_password).to_s
      ]
      configuration.each(&:freeze)
      configuration.freeze
    end

    def validated_base_url(configuration)
      url = configuration.fetch(0)
      parsed_url = URI.parse(url)

      unless parsed_url.is_a?(URI::HTTP) && parsed_url.host.present?
        raise URI::InvalidURIError, "BookOrbit URL must include http:// or https://"
      end

      url
    end

    def handle_response(response, success_statuses: [ 200 ])
      return yield(response.body.presence || {}) if response.status.in?(success_statuses)

      case response.status
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

    def extract_library_items(data, page:, page_size:)
      unless valid_library_items_page?(data, page: page, page_size: page_size)
        raise Error, "BookOrbit returned an invalid library inventory response"
      end

      items = data["items"].map do |raw_item|
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

      [ items, data["total"] ]
    end

    def valid_library_items_page?(data, page:, page_size:)
      return false unless data.is_a?(Hash)

      items = data["items"]
      total = data["total"]
      items.is_a?(Array) &&
        items.size <= page_size &&
        items.all? { |item| item.is_a?(Hash) && item["id"].present? } &&
        total.is_a?(Integer) && total >= (page * page_size) + items.size &&
        data["page"] == page &&
        data["size"] == page_size
    end
  end
end
