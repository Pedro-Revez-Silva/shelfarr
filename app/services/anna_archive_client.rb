# frozen_string_literal: true

require "uri"

# Client for interacting with Anna's Archive
# Search via HTML scraping, downloads via member API
class AnnaArchiveClient
  # Custom error classes
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthenticationError < Error; end
  class NotConfiguredError < Error; end
  class ConfigurationError < Error; end
  class ScrapingError < Error; end
  class BotProtectionError < Error; end
  class RetryableError < Error; end

  # Data structure for search results
  Result = Data.define(
    :md5, :title, :author, :year,
    :file_type, :file_size, :language
  ) do
    def downloadable?
      md5.present?
    end

    def size_human
      file_size
    end
  end

  DEFAULT_BASE_URL = "https://annas-archive.se"
  ALLOWED_BASE_URL_SCHEMES = %w[http https].freeze

  class << self
    # Check if Anna's Archive is configured (has API key)
    def configured?
      SettingsService.configured?(:anna_archive_api_key) &&
        SettingsService.get(:anna_archive_enabled, default: false)
    end

    # Check if Anna's Archive is enabled but not necessarily with key
    def enabled?
      SettingsService.get(:anna_archive_enabled, default: false)
    end

    # Search for books via HTML scraping
    # Returns array of Result
    # @param language [String] ISO 639-1 language code (e.g., "en", "fr", "de")
    def search(query, file_types: %w[epub pdf], limit: 50, language: nil)
      ensure_configured!

      url = build_search_url(query, file_types, language: language)
      Rails.logger.info "[AnnaArchiveClient] Searching: #{url}"

      html = fetch_with_rotation(url, context: "search")
      parse_search_results(html, limit)
    end

    # Get download URL (torrent) via fast_download API
    # Requires member API key
    def get_download_url(md5, path_index: 0, domain_index: 0)
      ensure_configured!

      params = {
        md5: md5,
        key: api_key,
        path_index: path_index,
        domain_index: domain_index
      }

      with_base_url_rotation(context: "download API") do |base_url|
        response = connection_for(base_url).get("/dyn/api/fast_download.json", params)
        raise RetryableError, "API request failed with status #{response.status}" unless response.status == 200

        data = JSON.parse(response.body)

        if data["error"]
          raise Error, "Anna's Archive API error: #{data['error']}"
        end

        download_url = data["download_url"]
        raise Error, "No download URL returned" if download_url.blank?

        download_url
      rescue JSON::ParserError => e
        raise RetryableError, "Failed to parse Anna's Archive response: #{e.message}"
      end
    end

    def info_url(md5)
      "#{preferred_base_url}/md5/#{md5}"
    end

    def reset_connection!
      @connections = nil
      @working_base_url = nil
    end

    # Test connection by fetching search page
    def test_connection
      configured_base_urls.any? do |base_url|
        response = connection_for(base_url).get("/")
        response.status == 200
      rescue Faraday::Error
        false
      end
    rescue Error
      false
    end

    private

    def fetch_with_rotation(path, context:)
      with_base_url_rotation(context: context) do |base_url|
        fetch_with_protection_bypass(path, base_url: base_url)
      end
    end

    def with_base_url_rotation(context:)
      last_error = nil
      bot_protection_error = nil

      ordered_base_urls.each do |base_url|
        return yield(base_url).tap { remember_working_base_url(base_url) }
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError,
             ConnectionError, BotProtectionError, RetryableError => e
        last_error = e
        bot_protection_error ||= e if e.is_a?(BotProtectionError)
        Rails.logger.debug "[AnnaArchiveClient] #{context} failed on #{base_url}: #{e.message}"
      end

      raise_rotation_error(bot_protection_error || last_error, context: context)
    end

    def fetch_with_protection_bypass(path, base_url:)
      url = "#{base_url}#{path}"

      if FlaresolverrClient.configured?
        Rails.logger.info "[AnnaArchiveClient] Using FlareSolverr for request"
        FlaresolverrClient.get(url)
      else
        response = connection_for(base_url).get(path)

        # Detect bot protection
        if response.status == 403 || bot_protection_detected?(response.body)
          raise BotProtectionError, "Anna's Archive requires FlareSolverr to bypass DDoS protection. " \
                                    "Please configure FlareSolverr URL in settings."
        end

        raise RetryableError, "Search failed with status #{response.status}" unless response.status == 200
        response.body
      end
    rescue FlaresolverrClient::Error => e
      raise ConnectionError, "FlareSolverr error: #{e.message}"
    end

    def bot_protection_detected?(html)
      return false if html.blank?

      html.include?("DDoS-Guard") ||
        html.include?("ddos-guard") ||
        html.include?("Checking your browser") ||
        html.include?("Just a moment") ||
        html.include?("Enable JavaScript and cookies")
    end

    def ensure_configured!
      unless configured?
        raise NotConfiguredError, "Anna's Archive is not configured or enabled"
      end

      configured_base_urls
    end

    def connection_for(base_url)
      @connections ||= {}
      @connections[base_url] ||= Faraday.new(url: base_url) do |f|
        f.request :url_encoded
        f.adapter Faraday.default_adapter
        f.headers["User-Agent"] = "Shelfarr/1.0"
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end

    def configured_base_urls
      raw_url = SettingsService.get(:anna_archive_url, default: DEFAULT_BASE_URL).to_s
      raw_url = DEFAULT_BASE_URL if raw_url.blank?

      raw_url.split(/[,\s]+/).filter_map do |url|
        normalize_base_url(url.strip)
      end.uniq.tap do |urls|
        raise ConfigurationError, "At least one valid Anna's Archive URL is required" if urls.empty?
      end
    end

    def normalize_base_url(url)
      return if url.blank?

      uri = URI.parse(url)
      unless ALLOWED_BASE_URL_SCHEMES.include?(uri.scheme) && uri.host.present?
        raise ConfigurationError, "Anna's Archive URL must be a valid http or https URL"
      end

      if uri.path.present? && uri.path != "/"
        raise ConfigurationError, "Anna's Archive URL must not include a path"
      end

      if uri.query.present? || uri.fragment.present? || uri.userinfo.present?
        raise ConfigurationError, "Anna's Archive URL must only include the site origin"
      end

      uri.to_s.delete_suffix("/")
    rescue URI::InvalidURIError => e
      raise ConfigurationError, "Anna's Archive URL is invalid: #{e.message}"
    end

    def ordered_base_urls
      urls = configured_base_urls
      return urls unless @working_base_url && urls.include?(@working_base_url)

      [ @working_base_url, *(urls - [ @working_base_url ]) ]
    end

    def remember_working_base_url(base_url)
      @working_base_url = base_url
    end

    def preferred_base_url
      urls = configured_base_urls
      return @working_base_url if @working_base_url && urls.include?(@working_base_url)

      urls.first
    rescue ConfigurationError
      DEFAULT_BASE_URL
    end

    def raise_rotation_error(error, context:)
      case error
      when nil
        raise ConnectionError, "Failed to connect to Anna's Archive #{context}"
      when Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError
        raise ConnectionError, "Failed to connect to Anna's Archive #{context}: #{error.message}"
      else
        raise error
      end
    end

    def api_key
      SettingsService.get(:anna_archive_api_key)
    end

    def build_search_url(query, file_types, language: nil)
      encoded_query = URI.encode_www_form_component(query)
      ext_param = Array(file_types).join(",")

      # Anna's Archive search URL pattern
      # Sort by "most_relevant" for best matches
      url = "/search?q=#{encoded_query}&ext=#{ext_param}&sort=&content=book_nonfiction,book_fiction,book_unknown"

      # Add language filter if specified
      # Anna's Archive uses ISO 639-1 codes (e.g., en, fr, de)
      url += "&lang=#{language}" if language.present?

      url
    end

    def parse_search_results(html, limit)
      require "nokogiri"

      doc = Nokogiri::HTML(html)
      results = []

      # Anna's Archive uses a specific structure for search results
      # Each result is typically in a div/article with a link to /md5/{hash}
      doc.css("a[href*='/md5/']").each do |link|
        break if results.size >= limit

        result = parse_result_element(link)
        results << result if result
      end

      Rails.logger.info "[AnnaArchiveClient] Parsed #{results.size} results"
      results
    rescue => e
      Rails.logger.error "[AnnaArchiveClient] Scraping error: #{e.message}"
      raise ScrapingError, "Failed to parse search results: #{e.message}"
    end

    def parse_result_element(link)
      href = link["href"]
      return nil unless href

      # Extract MD5 from URL like /md5/abc123def456...
      md5_match = href.match(/\/md5\/([a-f0-9]+)/i)
      return nil unless md5_match

      md5 = md5_match[1]

      # Get the parent container that holds all result info
      container = find_result_container(link)
      return nil unless container

      # Extract text content
      text = container.text.to_s

      # Try to parse title, author, and metadata from the text
      title = extract_title(container, link)
      author = extract_author(container, text)
      file_type = extract_file_type(container, text)
      file_size = extract_file_size(text)
      language = extract_language(text)
      year = extract_year(text)

      return nil if title.blank?

      Result.new(
        md5: md5,
        title: title,
        author: author,
        year: year,
        file_type: file_type,
        file_size: file_size,
        language: language
      )
    end

    def find_result_container(link)
      # Walk up the DOM to find the containing element
      # Anna's Archive typically wraps each result in a container
      parent = link
      5.times do
        break if parent.nil? || parent.is_a?(Nokogiri::HTML4::Document)
        parent = parent.parent
        break if parent.nil? || parent.is_a?(Nokogiri::HTML4::Document)
        # Look for a container that seems like a search result item
        if parent.name == "div" || parent.name == "article"
          # Check if it has enough content to be a result
          return parent if parent.text.to_s.length > 50
        end
      end
      # Fallback to link's parent if valid
      link.parent unless link.parent.is_a?(Nokogiri::HTML4::Document)
    end

    def extract_title(container, link)
      # The title is usually in the link element itself if it has certain classes
      # Look for the main title link with font-semibold text-lg
      title_link = container.at_css('a[class*="font-semibold"][class*="text-lg"]')
      return title_link.text.strip if title_link && title_link.text.present?

      # Or check if the link we found is the title link
      if link["class"]&.include?("font-semibold")
        return link.text.strip if link.text.present?
      end

      # Try to find a heading or prominent text
      heading = container.at_css("h3, h4, .title, [class*='title']")
      return heading.text.strip if heading && heading.text.present?

      # Look for data-content attribute which holds fallback title
      fallback = container.at_css('[data-content]')
      if fallback && fallback["data-content"].present?
        return fallback["data-content"]
      end

      nil
    end

    def extract_author(container, text)
      # Look for author link with user-edit icon
      author_link = container.at_css('a[href^="/search?q="] span[class*="user-edit"]')
      if author_link
        parent = author_link.parent
        return parent.text.strip if parent && parent.text.present?
      end

      # Look for author-specific elements
      author_el = container.at_css(".author, [class*='author']")
      return author_el.text.strip if author_el && author_el.text.present?

      # Look for data-content with author info
      author_fallback = container.css('[data-content]')[1]  # Second data-content is usually author
      if author_fallback && author_fallback["data-content"].present?
        return author_fallback["data-content"]
      end

      # Try common patterns: "by Author Name"
      if text =~ /\bby\s+([A-Z][^,\n\d]{3,50})/i
        return $1.strip
      end

      nil
    end

    def extract_file_type(container, text)
      # Look for file extension badges
      badge = container.at_css("[class*='badge'], [class*='ext'], [class*='format']")
      if badge
        ext = badge.text.strip.downcase
        return ext if %w[epub pdf mobi azw3 djvu mp3 m4b].include?(ext)
      end

      # Match from text
      if text =~ /\b(epub|pdf|mobi|azw3|djvu|mp3|m4b)\b/i
        return $1.downcase
      end

      nil
    end

    def extract_file_size(text)
      # Match patterns like "15.2 MB", "1.5 GB"
      if text =~ /(\d+(?:\.\d+)?)\s*(KB|MB|GB)/i
        "#{$1} #{$2.upcase}"
      end
    end

    def extract_language(text)
      # Common language patterns
      languages = {
        "english" => "en", "en" => "en",
        "spanish" => "es", "español" => "es", "es" => "es",
        "french" => "fr", "français" => "fr", "fr" => "fr",
        "german" => "de", "deutsch" => "de", "de" => "de",
        "portuguese" => "pt", "português" => "pt", "pt" => "pt",
        "italian" => "it", "italiano" => "it", "it" => "it",
        "russian" => "ru", "ru" => "ru",
        "chinese" => "zh", "zh" => "zh",
        "japanese" => "ja", "ja" => "ja"
      }

      text_lower = text.downcase
      languages.each do |pattern, code|
        return code if text_lower.include?(pattern)
      end

      nil
    end

    def extract_year(text)
      # Match 4-digit years between 1800 and 2030
      if text =~ /\b(1[89]\d{2}|20[0-2]\d)\b/
        $1.to_i
      end
    end
  end
end
