# frozen_string_literal: true

# Client for interacting with Audiobookshelf API
# https://api.audiobookshelf.org/
class AudiobookshelfClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthenticationError < Error; end
  class NotConfiguredError < Error; end

  Library = Data.define(:id, :name, :folders, :media_type) do
    def folder_paths
      folders.map { |f| f["fullPath"] }
    end

    def audiobook_library?
      media_type == "book"
    end

    def podcast_library?
      media_type == "podcast"
    end
  end

  class << self
    # GET /api/libraries - List all libraries with folder paths
    def libraries
      ensure_configured!

      response = request { connection.get("/api/libraries") }
      handle_response(response) do |data|
        (data["libraries"] || []).map { |lib| parse_library(lib) }
      end
    end

    # GET /api/libraries/:id - Get single library
    def library(id)
      ensure_configured!

      response = request { connection.get("/api/libraries/#{id}") }
      handle_response(response) { |data| parse_library(data) }
    end

    # POST /api/libraries/:id/scan - Trigger library scan
    def scan_library(id)
      ensure_configured!

      response = request { connection.post("/api/libraries/#{id}/scan") }
      response.status == 200
    end

    # GET /api/libraries/:id/items - List all items in a library
    def library_items(id, page_size: 500)
      ensure_configured!

      items = []
      page = 0

      loop do
        response = request { connection.get("/api/libraries/#{id}/items", { limit: page_size, page: page }) }
        break unless response.status == 200

        page_items = extract_library_items(response.body)
        items.concat(page_items)
        break if end_of_items?(page_items, response.body, page_size, page)
        page += 1
      end

      items
    end

    # GET /api/libraries/:id/items - Find item by path
    def find_item_by_path(path)
      ensure_configured!

      # Normalize path for comparison
      normalized_path = File.expand_path(path)

      # Search all configured libraries
      library_ids = [
        SettingsService.get(:audiobookshelf_audiobook_library_id),
        SettingsService.get(:audiobookshelf_ebook_library_id)
      ].compact.uniq

      library_ids.each do |lib_id|
        next if lib_id.blank?

        response = request { connection.get("/api/libraries/#{lib_id}/items") }
        next unless response.status == 200

        items = response.body["results"] || []
        item = items.find do |i|
          item_path = i["path"] || i.dig("media", "path")
          next false unless item_path
          File.expand_path(item_path) == normalized_path
        end

        return item if item
      end

      nil
    end

    # DELETE /api/library-items/:id - Delete a library item
    def delete_item(item_id)
      ensure_configured!

      response = request { connection.delete("/api/library-items/#{item_id}") }
      response.status == 200
    end

    # Find and delete item by path
    def delete_item_by_path(path)
      item = find_item_by_path(path)
      return false unless item

      delete_item(item["id"])
    end

    def configured?
      SettingsService.audiobookshelf_configured?
    end

    def test_connection
      ensure_configured!
      libraries.any?
    rescue Error
      false
    end

    def reset_connection!
      @connection = nil
    end

    private

    def ensure_configured!
      raise NotConfiguredError, "Audiobookshelf is not configured" unless configured?
    end

    def request
      yield
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError, URI::Error => e
      raise ConnectionError, "Failed to connect to Audiobookshelf: #{e.message}"
    end

    def connection
      @connection ||= Faraday.new(url: base_url) do |f|
        f.request :json
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.headers["Authorization"] = "Bearer #{api_key}"
        f.options.timeout = 15
        f.options.open_timeout = 5
      end
    end

    def base_url
      url = SettingsService.get(:audiobookshelf_url).to_s.strip
      parsed_url = URI.parse(url)

      unless parsed_url.is_a?(URI::HTTP) && parsed_url.host.present?
        raise URI::InvalidURIError, "Audiobookshelf URL must include http:// or https://"
      end

      url
    end

    def api_key
      SettingsService.get(:audiobookshelf_api_key)
    end

    def handle_response(response)
      case response.status
      when 200, 201
        yield response.body
      when 401, 403
        raise AuthenticationError, "Invalid Audiobookshelf API key"
      when 404
        raise Error, "Audiobookshelf resource not found"
      else
        raise Error, "Audiobookshelf API error: #{response.status}"
      end
    end

    def parse_library(data)
      Library.new(
        id: data["id"],
        name: data["name"],
        folders: data["folders"] || [],
        media_type: data["mediaType"]
      )
    end

    def extract_library_items(data)
      raw_items = data["results"] || data["items"] || data["libraryItems"] || []
      return [] unless raw_items.is_a?(Array)

      raw_items.filter_map do |raw_item|
        next unless raw_item.is_a?(Hash)

        metadata = extract_book_metadata(raw_item)

        {
          "audiobookshelf_id" => raw_item["id"] || raw_item.dig("media", "id") || raw_item.dig("item", "id"),
          "title" => extract_title(raw_item, metadata),
          "subtitle" => extract_subtitle(raw_item, metadata),
          "author" => extract_author(raw_item),
          "narrator" => extract_narrator(raw_item),
          "series" => extract_series_name(raw_item, metadata),
          "series_position" => extract_series_position(raw_item, metadata),
          "publisher" => metadata["publisher"] || raw_item["publisher"],
          "language" => metadata["language"] || raw_item["language"],
          "description" => metadata["description"] || raw_item["description"],
          "isbn" => normalize_identifier(metadata["isbn"] || raw_item["isbn"]),
          "asin" => metadata["asin"] || raw_item["asin"],
          "published_year" => extract_published_year(raw_item, metadata),
          "missing" => raw_item["isMissing"] == true
        }
      end
    end

    def extract_book_metadata(raw_item)
      raw_item.dig("media", "metadata") ||
        raw_item["metadata"] ||
        raw_item.dig("book", "metadata") ||
        {}
    end

    def extract_title(raw_item, metadata)
      raw_item["title"] ||
        metadata["title"] ||
        raw_item.dig("media", "title") ||
        raw_item.dig("book", "title")
    end

    def extract_subtitle(raw_item, metadata)
      raw_item["subtitle"] ||
        metadata["subtitle"] ||
        raw_item.dig("media", "subtitle") ||
        raw_item.dig("book", "subtitle")
    end

    def extract_author(raw_item)
      return raw_item["author"] if raw_item["author"].present?
      return raw_item["authorName"] if raw_item["authorName"].present?
      return raw_item.dig("media", "metadata", "authorName") if raw_item.dig("media", "metadata", "authorName").present?
      return raw_item.dig("media", "author") if raw_item.dig("media", "author").present?
      return raw_item.dig("metadata", "authorName") if raw_item.dig("metadata", "authorName").present?
      return raw_item.dig("book", "author") if raw_item.dig("book", "author").present?
      return raw_item.dig("book", "metadata", "authorName") if raw_item.dig("book", "metadata", "authorName").present?

      raw_authors = raw_item.dig("media", "authors") ||
        raw_item.dig("media", "metadata", "authors") ||
        raw_item.dig("metadata", "authors") ||
        raw_item.dig("book", "metadata", "authors")
      return nil if raw_authors.blank?

      if raw_authors.is_a?(Array)
        return raw_authors.join(", ") if raw_authors.all?(String)

        names = raw_authors.map do |author|
          next unless author.is_a?(Hash)

          author["name"] || author["fullName"] || author["author"]
        end.compact

        names.join(", ")
      else
        raw_authors.to_s
      end
    end

    def extract_narrator(raw_item)
      return raw_item["narrator"] if raw_item["narrator"].present?
      return raw_item["narratorName"] if raw_item["narratorName"].present?
      return raw_item.dig("media", "metadata", "narratorName") if raw_item.dig("media", "metadata", "narratorName").present?
      return raw_item.dig("metadata", "narratorName") if raw_item.dig("metadata", "narratorName").present?
      return raw_item.dig("book", "metadata", "narratorName") if raw_item.dig("book", "metadata", "narratorName").present?

      raw_narrators = raw_item.dig("media", "metadata", "narrators") ||
        raw_item.dig("metadata", "narrators") ||
        raw_item.dig("book", "metadata", "narrators")

      join_people(raw_narrators)
    end

    def extract_series_name(raw_item, metadata)
      return raw_item["seriesName"] if raw_item["seriesName"].present?
      return metadata["seriesName"] if metadata["seriesName"].present?

      first_series = first_series_entry(raw_item, metadata)
      return first_series["name"] if first_series.is_a?(Hash) && first_series["name"].present?
      return first_series["series"]["name"] if first_series.is_a?(Hash) && first_series.dig("series", "name").present?

      first_series.to_s if first_series.present?
    end

    def extract_series_position(raw_item, metadata)
      return raw_item["seriesSequence"] if raw_item["seriesSequence"].present?

      first_series = first_series_entry(raw_item, metadata)
      return first_series["sequence"] if first_series.is_a?(Hash) && first_series["sequence"].present?

      nil
    end

    def first_series_entry(raw_item, metadata)
      series = metadata["series"] || raw_item["series"] || raw_item.dig("book", "metadata", "series")
      return series.first if series.is_a?(Array)

      series
    end

    def extract_published_year(raw_item, metadata)
      value = metadata["publishedYear"] ||
        metadata["publishedDate"] ||
        raw_item["publishedYear"] ||
        raw_item["publishedDate"] ||
        raw_item["year"]
      return nil if value.blank?

      match = value.to_s.match(/\A\d{4}\z|(\d{4})/)
      return nil unless match

      (match[0] || match[1]).to_i
    end

    def normalize_identifier(value)
      return nil if value.blank?
      return value.compact_blank.first.to_s if value.is_a?(Array)

      value.to_s
    end

    def join_people(values)
      return nil if values.blank?

      if values.is_a?(Array)
        return values.join(", ") if values.all?(String)

        names = values.map do |value|
          next unless value.is_a?(Hash)

          value["name"] || value["fullName"]
        end.compact

        return names.join(", ") if names.any?
      end

      values.to_s
    end

    def end_of_items?(page_items, data, page_size, page)
      return true if page_items.empty?
      return true if page_items.length < page_size

      total = data["total"] || data["totalItems"] || data["total_items"] || data["total_results"]
      return true if total.present? && total <= ((page + 1) * page_size)

      total_pages = data["totalPages"] || data["pages"] || data["total_pages"]
      current_page = data["page"] || page
      return true if total_pages.present? && (current_page + 1) >= total_pages

      false
    end
  end
end
