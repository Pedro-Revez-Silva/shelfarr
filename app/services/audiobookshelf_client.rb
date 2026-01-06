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
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
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
      SettingsService.get(:audiobookshelf_url)
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
  end
end
