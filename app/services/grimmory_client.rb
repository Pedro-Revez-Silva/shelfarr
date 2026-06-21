# frozen_string_literal: true

# Client for Grimmory's documented /api/v1 endpoints.
class GrimmoryClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthenticationError < Error; end
  class NotConfiguredError < Error; end

  Library = Data.define(:id, :name, :paths, :media_type) do
    def folder_paths
      paths.map { |path| path["path"] || path["fullPath"] }.compact
    end

    def audiobook_library?
      true
    end

    def podcast_library?
      false
    end

    def folders
      paths
    end
  end

  class << self
    def libraries
      ensure_configured!

      response = authenticated_request { connection.get("/api/v1/libraries") }
      handle_response(response) do |data|
        extract_collection(data, "libraries").map { |library| parse_library(library) }
      end
    end

    def library(id)
      ensure_configured!

      response = authenticated_request { connection.get("/api/v1/libraries/#{id}") }
      handle_response(response) { |data| parse_library(data) }
    end

    def library_items(id, page_size: 200)
      ensure_configured!

      response = authenticated_request { connection.get("/api/v1/libraries/#{id}/book") }
      handle_response(response) do |data|
        extract_collection(data, "books").filter_map { |item| parse_item(item) }
      end
    end

    def scan_library(id)
      ensure_configured!

      response = authenticated_request { connection.put("/api/v1/libraries/#{id}/refresh") }
      response.status.in?([ 200, 201, 202, 204 ])
    end

    def delete_item_by_path(_path)
      false
    end

    def configured?
      SettingsService.grimmory_configured?
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
      raise NotConfiguredError, "Grimmory is not configured" unless configured?
    end

    def request
      yield
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError, URI::Error => e
      raise ConnectionError, "Failed to connect to Grimmory: #{e.message}"
    end

    def authenticated_request
      response = request { yield }
      return response unless response.status.in?([ 401, 403 ]) && @access_token.present?

      reset_connection!
      request { yield }
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
            username: SettingsService.get(:grimmory_username),
            password: SettingsService.get(:grimmory_password)
          })
        end
        handle_response(response) do |data|
          token = data["accessToken"]
          raise AuthenticationError, "Grimmory login did not return an access token" if token.blank?

          token
        end
      end
    end

    def base_url
      url = SettingsService.get(:grimmory_url).to_s.strip
      parsed_url = URI.parse(url)

      unless parsed_url.is_a?(URI::HTTP) && parsed_url.host.present?
        raise URI::InvalidURIError, "Grimmory URL must include http:// or https://"
      end

      url
    end

    def handle_response(response)
      case response.status
      when 200, 201, 202, 204
        yield(response.body.presence || {})
      when 401, 403
        raise AuthenticationError, "Invalid Grimmory credentials or permissions"
      when 404
        raise Error, "Grimmory resource not found"
      else
        raise Error, "Grimmory API error: #{response.status}"
      end
    end

    def parse_library(data)
      Library.new(
        id: data["id"].to_s,
        name: data["name"],
        paths: data["paths"] || [],
        media_type: infer_media_type(data["allowedFormats"])
      )
    end

    def infer_media_type(allowed_formats)
      formats = Array(allowed_formats).map { |format| format.to_s.downcase.delete_prefix(".") }
      return "grimmory" if formats.empty?

      ebook_formats = %w[azw azw3 cbx cbz cbr epub fb2 lit lrf mobi pdf txt]
      audiobook_formats = %w[aac aiff alac audiobook flac m4a m4b mp3 ogg opus wav wma]

      has_ebooks = formats.any? { |format| ebook_formats.include?(format) }
      has_audiobooks = formats.any? { |format| audiobook_formats.include?(format) }

      return "audiobook" if has_audiobooks && !has_ebooks
      return "ebook" if has_ebooks && !has_audiobooks

      "grimmory"
    end

    def extract_collection(data, preferred_key)
      return data if data.is_a?(Array)
      return [] unless data.is_a?(Hash)

      data[preferred_key] || data["items"] || data["results"] || data["data"] || []
    end

    def parse_item(raw_item)
      return unless raw_item.is_a?(Hash)

      {
        "audiobookshelf_id" => item_id(raw_item),
        "title" => raw_item["title"] || raw_item.dig("metadata", "title"),
        "subtitle" => raw_item["subtitle"] || raw_item.dig("metadata", "subtitle"),
        "author" => extract_author(raw_item),
        "narrator" => extract_narrator(raw_item),
        "series" => extract_series_name(raw_item),
        "series_position" => extract_series_position(raw_item)&.to_s,
        "publisher" => extract_named_value(raw_item["publisher"] || raw_item.dig("metadata", "publisher")),
        "language" => raw_item["language"] || raw_item.dig("metadata", "language"),
        "description" => raw_item["description"] || raw_item.dig("metadata", "description"),
        "isbn" => extract_isbn(raw_item),
        "asin" => raw_item["asin"] || raw_item.dig("metadata", "asin"),
        "published_year" => extract_published_year(raw_item),
        "missing" => missing?(raw_item)
      }
    end

    def item_id(raw_item)
      (raw_item["id"] || raw_item["bookId"] || raw_item.dig("book", "id")).to_s
    end

    def extract_author(raw_item)
      return raw_item["author"] if raw_item["author"].present?
      return raw_item["authorName"] if raw_item["authorName"].present?
      return raw_item.dig("metadata", "author") if raw_item.dig("metadata", "author").present?
      return raw_item.dig("metadata", "authorName") if raw_item.dig("metadata", "authorName").present?

      join_people(raw_item["authors"] || raw_item.dig("metadata", "authors"))
    end

    def extract_narrator(raw_item)
      return raw_item["narrator"] if raw_item["narrator"].present?
      return raw_item["narratorName"] if raw_item["narratorName"].present?
      return raw_item.dig("metadata", "narrator") if raw_item.dig("metadata", "narrator").present?
      return raw_item.dig("metadata", "narratorName") if raw_item.dig("metadata", "narratorName").present?

      join_people(raw_item["narrators"] || raw_item.dig("metadata", "narrators"))
    end

    def extract_series_name(raw_item)
      return raw_item["seriesName"] if raw_item["seriesName"].present?
      return raw_item.dig("metadata", "seriesName") if raw_item.dig("metadata", "seriesName").present?

      extract_named_value(first_series_entry(raw_item))
    end

    def extract_series_position(raw_item)
      series = first_series_entry(raw_item)

      raw_item["seriesPosition"] ||
        raw_item["seriesIndex"] ||
        raw_item["seriesSequence"] ||
        raw_item.dig("metadata", "seriesPosition") ||
        raw_item.dig("metadata", "seriesIndex") ||
        raw_item.dig("metadata", "seriesNumber") ||
        raw_item.dig("metadata", "seriesSequence") ||
        (series.is_a?(Hash) ? series["position"] || series["sequence"] : nil)
    end

    def first_series_entry(raw_item)
      series = raw_item["series"] || raw_item.dig("metadata", "series")
      series.is_a?(Array) ? series.first : series
    end

    def extract_isbn(raw_item)
      raw_item["isbn13"].presence ||
        raw_item.dig("metadata", "isbn13").presence ||
        raw_item["isbn10"].presence ||
        raw_item.dig("metadata", "isbn10").presence ||
        normalize_identifier(raw_item["isbn"] || raw_item.dig("metadata", "isbn"))
    end

    def extract_published_year(raw_item)
      value = raw_item["publishedYear"] ||
        raw_item.dig("metadata", "publishedYear") ||
        raw_item["publishedDate"] ||
        raw_item.dig("metadata", "publishedDate")
      return nil if value.blank?

      match = value.to_s.match(/\A\d{4}\z|(\d{4})/)
      return nil unless match

      (match[0] || match[1]).to_i
    end

    def missing?(raw_item)
      raw_item["missing"] == true || raw_item["isMissing"] == true || raw_item["status"].to_s.downcase == "missing"
    end

    def join_people(values)
      return nil if values.blank?
      return values.join(", ") if values.is_a?(Array) && values.all?(String)

      if values.is_a?(Array)
        names = values.map { |value| extract_named_value(value) }.compact_blank
        return names.join(", ") if names.any?
      end

      extract_named_value(values)
    end

    def extract_named_value(value)
      return nil if value.blank?
      return value if value.is_a?(String)

      if value.is_a?(Hash)
        return value["name"] || value["fullName"] || value["title"] || value.dig("series", "name")
      end

      value.to_s
    end

    def normalize_identifier(value)
      return nil if value.blank?
      return value.compact_blank.first.to_s if value.is_a?(Array)

      value.to_s
    end
  end
end
