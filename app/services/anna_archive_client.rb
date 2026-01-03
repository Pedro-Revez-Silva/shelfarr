# frozen_string_literal: true

# Client for interacting with Anna's Archive
# Search via HTML scraping, downloads via member API
class AnnaArchiveClient
  # Custom error classes
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthenticationError < Error; end
  class NotConfiguredError < Error; end
  class ScrapingError < Error; end

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
    def search(query, file_types: %w[epub pdf], limit: 50)
      ensure_configured!

      url = build_search_url(query, file_types)
      Rails.logger.info "[AnnaArchiveClient] Searching: #{url}"

      response = connection.get(url)

      unless response.status == 200
        raise Error, "Anna's Archive search failed with status #{response.status}"
      end

      parse_search_results(response.body, limit)
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise ConnectionError, "Failed to connect to Anna's Archive: #{e.message}"
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

      response = connection.get("/dyn/api/fast_download.json", params)
      data = JSON.parse(response.body)

      if data["error"]
        raise Error, "Anna's Archive API error: #{data['error']}"
      end

      download_url = data["download_url"]
      raise Error, "No download URL returned" if download_url.blank?

      download_url
    rescue JSON::ParserError => e
      raise Error, "Failed to parse Anna's Archive response: #{e.message}"
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise ConnectionError, "Failed to connect to Anna's Archive API: #{e.message}"
    end

    # Test connection by fetching search page
    def test_connection
      response = connection.get("/")
      response.status == 200
    rescue Error, Faraday::Error
      false
    end

    private

    def ensure_configured!
      unless configured?
        raise NotConfiguredError, "Anna's Archive is not configured or enabled"
      end
    end

    def connection
      @connection ||= Faraday.new(url: base_url) do |f|
        f.request :url_encoded
        f.adapter Faraday.default_adapter
        f.headers["User-Agent"] = "Shelfarr/1.0"
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end

    def base_url
      SettingsService.get(:anna_archive_url, default: "https://annas-archive.org")
    end

    def api_key
      SettingsService.get(:anna_archive_api_key)
    end

    def build_search_url(query, file_types)
      encoded_query = URI.encode_www_form_component(query)
      ext_param = Array(file_types).join(",")

      # Anna's Archive search URL pattern
      # Sort by "most_relevant" for best matches
      "/search?q=#{encoded_query}&ext=#{ext_param}&sort=&content=book_nonfiction,book_fiction,book_unknown"
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
