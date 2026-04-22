# frozen_string_literal: true

require "digest"
require "uri"

# Client for interacting with Z-Library's internal eAPI.
# This integration is unofficial and may break if the service changes.
class ZLibraryClient
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthenticationError < Error; end
  class NotConfiguredError < Error; end
  class RateLimitError < Error; end
  class ConfigurationError < Error; end

  Result = Data.define(
    :id, :hash, :title, :author, :year,
    :file_type, :file_size, :language
  ) do
    def downloadable?
      id.present? && hash.present?
    end
  end

  AUTH_TTL_SECONDS = 30.minutes
  ALLOWED_DOWNLOAD_SCHEMES = %w[http https].freeze

  class << self
    def configured?
      SettingsService.zlibrary_configured?
    end

    def test_connection
      ensure_configured!
      login.present?
    rescue Error => e
      Rails.logger.error "[ZLibraryClient] Connection test failed: #{e.message}"
      false
    end

    def search(query, file_types: %w[epub pdf], limit: 50, language: nil)
      ensure_configured!

      auth = login
      Rails.logger.info "[ZLibraryClient] Searching for '#{query}'"

      payload = [["message", query], ["limit", limit.to_s]]
      Array(file_types).each { |ext| payload << ["extensions[]", ext] }
      payload << ["languages[]", language] if language.present?

      response = connection.post("https://#{auth[:domain]}/eapi/book/search") do |req|
        req.headers["Cookie"] = cookie_header(auth)
        req.body = URI.encode_www_form(payload)
      end

      data = parse_response(response, context: "search")
      parse_search_results(data.fetch("books", []), limit)
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise ConnectionError, "Failed to connect to Z-Library: #{e.message}"
    end

    def get_download_url(id:, hash:)
      ensure_configured!

      auth = login
      response = connection.get("https://#{auth[:domain]}/eapi/book/#{id}/#{hash}/file") do |req|
        req.headers["Cookie"] = cookie_header(auth)
      end

      data = parse_response(response, context: "download lookup")
      download_link = data.dig("file", "downloadLink")
      raise Error, "Z-Library did not return a download link" if download_link.blank?

      validate_download_url!(download_link)
      download_link
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise ConnectionError, "Failed to connect to Z-Library: #{e.message}"
    end

    def reset_connection!
      @auth_cache = nil
      @connection = nil
    end

    private

    def login
      cached = @auth_cache
      signature = credential_signature

      if cached.present? &&
          cached[:signature] == signature &&
          cached[:expires_at] > Time.current
        return cached[:auth]
      end

      auth = perform_login(signature)
      raise AuthenticationError, "Z-Library login failed" unless auth

      auth
    end

    def perform_login(signature)
      email = SettingsService.get(:zlibrary_email).to_s.strip
      password = SettingsService.get(:zlibrary_password).to_s
      domain = configured_domain

      response = connection.post("https://#{domain}/eapi/user/login") do |req|
        req.body = URI.encode_www_form(email: email, password: password)
      end

      return nil unless response.status == 200

      data = parse_json_body(response)
      return nil unless data["success"] == 1

      auth = {
        remix_userid: data.dig("user", "id")&.to_s,
        remix_userkey: data.dig("user", "remix_userkey")&.to_s,
        domain: domain
      }

      return nil if auth[:remix_userid].blank? || auth[:remix_userkey].blank?

      Rails.logger.info "[ZLibraryClient] Login succeeded via #{domain}"
      @auth_cache = {
        signature: signature,
        auth: auth,
        expires_at: Time.current + AUTH_TTL_SECONDS
      }
      auth
    rescue JSON::ParserError, Faraday::Error => e
      Rails.logger.debug "[ZLibraryClient] Login failed on #{domain}: #{e.message}"
      nil
    end

    def ensure_configured!
      raise NotConfiguredError, "Z-Library is not configured" unless configured?
      configured_domain
    end

    def credential_signature
      Digest::SHA256.hexdigest([
        SettingsService.get(:zlibrary_enabled, default: false),
        SettingsService.get(:zlibrary_url).to_s,
        SettingsService.get(:zlibrary_email).to_s,
        SettingsService.get(:zlibrary_password).to_s
      ].join("\0"))
    end

    def configured_domain
      configured_uri.host
    end

    def configured_uri
      raw_url = SettingsService.get(:zlibrary_url).to_s.strip
      raise ConfigurationError, "Z-Library URL is not configured" if raw_url.blank?

      uri = URI.parse(raw_url)
      unless ALLOWED_DOWNLOAD_SCHEMES.include?(uri.scheme) && uri.host.present?
        raise ConfigurationError, "Z-Library URL must be a valid http or https URL"
      end

      if uri.path.present? && uri.path != "/"
        raise ConfigurationError, "Z-Library URL must not include a path"
      end

      if uri.query.present? || uri.fragment.present? || uri.userinfo.present?
        raise ConfigurationError, "Z-Library URL must only include the site origin"
      end

      uri
    rescue URI::InvalidURIError => e
      raise ConfigurationError, "Z-Library URL is invalid: #{e.message}"
    end

    def connection
      @connection ||= Faraday.new do |f|
        f.request :url_encoded
        f.response :json, parser_options: { symbolize_names: false }, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
        f.headers["Content-Type"] = "application/x-www-form-urlencoded"
        f.headers["User-Agent"] = "Shelfarr/1.0"
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end

    def cookie_header(auth)
      "remix_userid=#{auth[:remix_userid]}; remix_userkey=#{auth[:remix_userkey]}"
    end

    def parse_response(response, context:)
      case response.status
      when 200
        data = parse_json_body(response)
        if data["success"] == 0
          error_message = data["error"].presence || "unknown Z-Library error"
          raise Error, "Z-Library #{context} failed: #{error_message}"
        end
        data
      when 401, 403
        raise AuthenticationError, "Invalid Z-Library credentials"
      when 429
        raise RateLimitError, "Z-Library rate limit exceeded"
      else
        raise ConnectionError, "Z-Library #{context} failed with status #{response.status}"
      end
    end

    def parse_json_body(response)
      return response.body if response.body.is_a?(Hash)

      JSON.parse(response.body)
    end

    def validate_download_url!(url)
      uri = URI.parse(url)
      unless ALLOWED_DOWNLOAD_SCHEMES.include?(uri.scheme) && uri.host.present?
        raise Error, "Z-Library returned an invalid download URL"
      end
    rescue URI::InvalidURIError => e
      raise Error, "Z-Library returned an invalid download URL: #{e.message}"
    end

    def parse_search_results(books, limit)
      Array(books).first(limit).filter_map do |book|
        id = book["id"]&.to_s
        hash = book["hash"]&.to_s
        next if id.blank? || hash.blank?

        Result.new(
          id: id,
          hash: hash,
          title: book["name"].presence || book["title"].presence || "Unknown",
          author: book["author"].presence,
          year: book["year"]&.to_i&.nonzero?,
          file_type: book["extension"]&.to_s&.downcase,
          file_size: book["filesize"]&.to_i&.nonzero?,
          language: normalize_language(book["language"])
        )
      end
    end

    def normalize_language(language)
      value = language.to_s.strip
      return if value.blank?

      direct_match = ReleaseParserService.language_info(value)
      return value if direct_match

      matched_code, = ReleaseParserService::LANGUAGES.find do |code, info|
        code.casecmp?(value) || info[:name].casecmp?(value)
      end

      matched_code || value.downcase
    end
  end
end
