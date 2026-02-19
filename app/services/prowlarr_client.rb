# frozen_string_literal: true

# Client for interacting with the Prowlarr API
# https://wiki.servarr.com/prowlarr/api
class ProwlarrClient
  # Custom error classes
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthenticationError < Error; end
  class NotConfiguredError < Error; end

  # Data structure for search results
  Result = Data.define(
    :guid, :title, :indexer, :size_bytes, :seeders, :leechers,
    :download_url, :magnet_url, :info_url, :published_at
  ) do
    def downloadable?
      download_url.present? || magnet_url.present?
    end

    def download_link
      magnet_url.presence || download_url
    end

    def size_human
      return nil unless size_bytes

      ActiveSupport::NumberHelper.number_to_human_size(size_bytes)
    end
  end

  # Newznab/Prowlarr category IDs
  CATEGORIES = {
    audiobook: [3030],           # Audio/Audiobook
    ebook: [7020, 7000],         # Books/EBook, Books
    all_books: [3030, 7020, 7000]
  }.freeze

  class << self
    # Search for books via Prowlarr indexers
    # Returns array of Result
    def search(query, categories: nil, book_type: nil, limit: 100)
      ensure_configured!

      # Use general search type to get results from all categories
      # limit defaults to 100 to match Prowlarr UI behavior (0 returns no results)
      params = { query: query, type: "search", limit: limit }

      # Apply category filtering based on book type
      # Categories must be passed as array, not comma-separated string
      cats = categories || categories_for_type(book_type)
      params[:categories] = Array(cats) if cats.present?

      # Filter by indexer tags if configured
      indexer_ids = filtered_indexer_ids
      params[:indexerIds] = indexer_ids if indexer_ids.present?

      response = request { connection.get("api/v1/search", params) }

      handle_response(response) do |data|
        Array(data).map { |item| parse_result(item) }
      end
    end

    # Fetch all indexers from Prowlarr
    def indexers
      ensure_configured!

      response = request { connection.get("api/v1/indexer") }

      handle_response(response) do |data|
        Array(data)
      end
    end

    # Get indexer IDs filtered by configured tags
    # Returns nil if no tags configured (use all indexers)
    def filtered_indexer_ids
      tags = indexer_filter_tags.map(&:to_s).map(&:downcase)
      return nil if tags.empty?

      all_indexers = indexers
      filtered = all_indexers.select do |indexer|
        indexer_tags = normalized_indexer_tags(indexer["tags"])
        (indexer_tags & tags).any?
      end

      filtered.map { |i| i["id"] }
    rescue Error => e
      Rails.logger.warn "[ProwlarrClient] Failed to fetch indexers for tag filtering: #{e.message}"
      nil
    end

    # Parse configured tags from settings
    def configured_tags
      tags_setting = SettingsService.get(:prowlarr_tags).to_s.strip
      return [] if tags_setting.blank?

      tags_setting.split(",").map { |t| t.strip.to_i }.reject(&:zero?)
    end

    def configured_tag_names
      tags_setting = SettingsService.get(:prowlarr_tags).to_s.strip
      return [] if tags_setting.blank?

      tags_setting.split(",").map { |t| t.strip }.reject do |tag|
        tag.blank? || tag.match?(/\A\d+\z/)
      end
    end

    def indexer_filter_tags
      configured_tags.concat(configured_tag_ids_for_names(configured_tag_names)).uniq
    end

    def configured_tag_ids_for_names(tag_names)
      return [] if tag_names.empty?

      response = request { connection.get("api/v1/tag") }
      handle_response(response) do |tags|
        tag_lookup = {}
        Array(tags).each do |tag|
          next unless tag.is_a?(Hash)

          label = tag["label"] || tag["name"] || tag["tag"]
          next if label.blank?

          tag_id = tag["id"] || tag["tagId"]
          next if tag_id.blank?

          tag_lookup[label.to_s.strip.downcase] = tag_id.to_i
        end

        tag_names.filter_map do |name|
          tag_lookup[name.to_s.downcase]
        end
      end
    rescue Error => e
      Rails.logger.warn "[ProwlarrClient] Failed to resolve tag names for filtering: #{e.message}"
      []
    end

    def normalized_indexer_tags(tags)
      values = tags.to_a.flat_map do |tag|
        case tag
        when Hash
          [tag["id"], tag["label"], tag["name"]]
        else
          tag
        end
      end

      values.compact.map(&:to_s).map(&:downcase)
    end

    # Get appropriate categories for a book type
    def categories_for_type(book_type)
      case book_type&.to_sym
      when :audiobook
        CATEGORIES[:audiobook]
      when :ebook
        CATEGORIES[:ebook]
      else
        CATEGORIES[:all_books]
      end
    end

    # Check if Prowlarr is configured
    def configured?
      SettingsService.prowlarr_configured?
    end

    # Test connection to Prowlarr
    # Uses /api/v1/indexer instead of /api/v1/health because the health
    # endpoint may not require authentication, masking invalid API keys.
    def test_connection
      ensure_configured!

      response = connection.get("api/v1/indexer")
      response.status == 200
    rescue Error, Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError
      false
    end

    # Reset cached connection (for tests)
    def reset_connection!
      @connection = nil
    end

    private

    def ensure_configured!
      raise NotConfiguredError, "Prowlarr is not configured" unless configured?
    end

    def request
      yield
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise ConnectionError, "Failed to connect to Prowlarr: #{e.message}"
    end

    def connection
      @connection ||= Faraday.new(url: base_url) do |f|
        # Use flat params encoder so arrays are sent as key=val1&key=val2
        # instead of key[]=val1&key[]=val2 (which Prowlarr doesn't understand)
        f.options.params_encoder = Faraday::FlatParamsEncoder
        f.request :url_encoded
        f.response :json, parser_options: { symbolize_names: false }
        f.adapter Faraday.default_adapter
        f.headers["X-Api-Key"] = api_key
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end

    def base_url
      url = SettingsService.get(:prowlarr_url).to_s.strip
      # Ensure URL ends with trailing slash for proper URI joining
      url.end_with?("/") ? url : "#{url}/"
    end

    def api_key
      SettingsService.get(:prowlarr_api_key)
    end

    def handle_response(response)
      case response.status
      when 200
        yield response.body
      when 401, 403
        raise AuthenticationError, "Invalid Prowlarr API key"
      when 404
        raise Error, "Prowlarr endpoint not found"
      else
        raise Error, "Prowlarr API error: #{response.status}"
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise ConnectionError, "Failed to connect to Prowlarr: #{e.message}"
    end

    def parse_result(item)
      Result.new(
        guid: item["guid"],
        title: item["title"],
        indexer: item["indexer"],
        size_bytes: item["size"],
        seeders: item["seeders"],
        leechers: item["leechers"],
        download_url: extract_download_url(item),
        magnet_url: extract_magnet_url(item),
        info_url: item["infoUrl"],
        published_at: parse_date(item["publishDate"])
      )
    end

    def extract_download_url(item)
      url = item["downloadUrl"]
      return nil if url.blank?
      return nil if url.start_with?("magnet:")

      Rails.logger.debug "[ProwlarrClient] Received download URL from indexer '#{item['indexer']}' (#{url.length} chars): #{url.truncate(100)}"
      url
    end

    def extract_magnet_url(item)
      magnet = item["magnetUrl"]
      return magnet if magnet.present?

      # Some indexers put magnet in downloadUrl
      url = item["downloadUrl"]
      url if url.present? && url.start_with?("magnet:")
    end

    def parse_date(date_string)
      return nil if date_string.blank?

      Time.parse(date_string)
    rescue ArgumentError
      nil
    end
  end
end
