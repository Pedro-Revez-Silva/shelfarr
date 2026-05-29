# frozen_string_literal: true

require "uri"

class LibrivoxClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class NotConfiguredError < Error; end
  class ConfigurationError < Error; end

  Result = Data.define(
    :id, :title, :author, :language, :year,
    :file_type, :download_url, :info_url, :duration
  ) do
    def downloadable?
      download_url.present?
    end

    def language_display_name
      return nil if language.blank?

      ReleaseParserService.language_info(language)&.dig(:name) || language
    end
  end

  DEFAULT_BASE_URL = "https://librivox.org"
  ALLOWED_BASE_URL_SCHEMES = %w[http https].freeze

  class << self
    def configured?
      SettingsService.librivox_configured?
    end

    def test_connection
      search(title: nil, limit: 1)
      true
    rescue Error => e
      Rails.logger.error "[LibrivoxClient] Connection test failed: #{e.message}"
      false
    end

    def search(title:, author: nil, language: nil, limit: nil)
      ensure_configured!

      response = request do
        connection.get("/api/feed/audiobooks/") do |req|
          req.params["format"] = "json"
          req.params["extended"] = "1"
          req.params["coverart"] = "1"
          req.params["limit"] = limit || SettingsService.get(:librivox_search_limit, default: 20)
          req.params["title"] = title if title.present?
          req.params["author"] = author_last_name(author) if title.blank? && author.present?
        end
      end

      return [] if response.status == 404

      raise ConnectionError, "LibriVox search failed with status #{response.status}" unless response.status == 200

      parse_results(response.body, language: language)
    rescue JSON::ParserError => e
      raise ConnectionError, "Failed to parse LibriVox response: #{e.message}"
    end

    def reset_connection!
      @connection = nil
    end

    private

    def ensure_configured!
      raise NotConfiguredError, "LibriVox is not enabled" unless configured?
      base_url
    end

    def connection
      @connection ||= Faraday.new(url: base_url) do |f|
        f.request :url_encoded
        f.response :json, parser_options: { symbolize_names: false }, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
        f.headers["User-Agent"] = "Shelfarr/1.0"
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end

    def request
      yield
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise ConnectionError, "Failed to connect to LibriVox: #{e.message}"
    rescue URI::Error, ArgumentError => e
      raise ConnectionError, "Invalid LibriVox URL: #{e.message}"
    end

    def base_url
      normalize_base_url(SettingsService.get(:librivox_url, default: DEFAULT_BASE_URL))
    end

    def normalize_base_url(url)
      value = url.to_s.strip.presence || DEFAULT_BASE_URL
      uri = URI.parse(value)

      unless ALLOWED_BASE_URL_SCHEMES.include?(uri.scheme) && uri.host.present?
        raise ConfigurationError, "LibriVox URL must be a valid http or https URL"
      end

      if uri.path.present? && uri.path != "/"
        raise ConfigurationError, "LibriVox URL must not include a path"
      end

      if uri.query.present? || uri.fragment.present? || uri.userinfo.present?
        raise ConfigurationError, "LibriVox URL must only include the site origin"
      end

      uri.to_s.delete_suffix("/")
    rescue URI::InvalidURIError => e
      raise ConfigurationError, "LibriVox URL is invalid: #{e.message}"
    end

    def parse_results(body, language:)
      data = body.is_a?(Hash) ? body : JSON.parse(body)
      books = Array(data["books"])
      requested_language = language.to_s.presence

      books.filter_map do |book|
        result = parse_book(book)
        next unless result&.downloadable?
        next if requested_language.present? && result.language.present? && result.language != requested_language

        result
      end
    end

    def parse_book(book)
      id = book["id"].to_s
      title = book["title"].to_s.strip
      download_url = normalize_download_url(book["url_zip_file"])
      return if id.blank? || title.blank? || download_url.blank?

      Result.new(
        id: id,
        title: title,
        author: author_name(book["authors"]),
        language: language_code(book["language"]),
        year: book["copyright_year"].presence,
        file_type: "audiobook zip",
        download_url: download_url,
        info_url: book["url_librivox"].presence || book["url_project"].presence,
        duration: book["totaltime"].presence
      )
    end

    def author_name(authors)
      first = Array(authors).first
      return if first.blank?

      [ first["first_name"], first["last_name"] ].compact_blank.join(" ").presence
    end

    def author_last_name(author)
      value = author.to_s.strip
      return value.split(",", 2).first.strip if value.include?(",")

      value.split(/\s+/).last
    end

    def normalize_download_url(url)
      url.to_s.strip.gsub(" ", "%20")
    end

    def language_code(value)
      normalized = value.to_s.strip.downcase
      return if normalized.blank?

      ReleaseParserService::LANGUAGES.find do |_, info|
        info[:name].downcase == normalized
      end&.first
    end
  end
end
