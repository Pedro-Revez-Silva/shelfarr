# frozen_string_literal: true

require "faraday"
require "nokogiri"
require "uri"

class GutenbergClient
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ConnectionError < Error; end
  class NotConfiguredError < Error; end

  Result = Data.define(
    :id, :title, :author, :language, :year,
    :file_type, :download_url, :info_url
  ) do
    def downloadable?
      download_url.present?
    end

    def language_display_name
      return nil if language.blank?

      ReleaseParserService.language_info(language)&.dig(:name) || language
    end
  end

  DEFAULT_BASE_URL = "https://www.gutenberg.org"
  USER_AGENT = "Shelfarr/1.0 (+https://github.com/Pedro-Revez-Silva/shelfarr)"

  class << self
    def configured?
      SettingsService.gutenberg_configured?
    end

    def search(title:, author: nil, language: nil, limit: nil)
      raise NotConfiguredError, "Project Gutenberg is not enabled" unless configured?

      query = [ title, author ].compact_blank.join(" ")
      return [] if query.blank?

      response = connection.get("/ebooks/search.opds/") do |req|
        req.params["query"] = query
      end

      return [] if response.status == 404
      raise ConnectionError, "Project Gutenberg search failed with status #{response.status}" unless response.status == 200

      search_entries = parse_search_entries(response.body)
      search_entries.first(search_limit(limit)).filter_map do |entry|
        fetch_book_result(entry, requested_language: language)
      end
    rescue Nokogiri::XML::SyntaxError => e
      raise ConnectionError, "Failed to parse Project Gutenberg response: #{e.message}"
    rescue Faraday::Error => e
      raise ConnectionError, "Project Gutenberg request failed: #{e.message}"
    end

    def test_connection
      raise NotConfiguredError, "Project Gutenberg is not enabled" unless configured?

      search(title: "pride prejudice", language: "en", limit: 1)
      true
    rescue Error
      false
    end

    def reset_connection!
      @connection = nil
      @base_url = nil
    end

    def base_url
      @base_url ||= normalize_base_url(SettingsService.get(:gutenberg_url, default: DEFAULT_BASE_URL))
    end

    private

    def connection
      @connection ||= Faraday.new(url: base_url) do |faraday|
        faraday.headers["User-Agent"] = USER_AGENT
        faraday.options.timeout = 30
        faraday.options.open_timeout = 10
        faraday.adapter Faraday.default_adapter
      end
    end

    def normalize_base_url(url)
      uri = URI.parse(url.to_s.strip)
      raise ConfigurationError, "Project Gutenberg URL must be a valid http or https URL" unless %w[http https].include?(uri.scheme)
      raise ConfigurationError, "Project Gutenberg URL must include a host" if uri.host.blank?
      raise ConfigurationError, "Project Gutenberg URL must only include the site origin" if uri.path.present? && uri.path != "/"
      raise ConfigurationError, "Project Gutenberg URL must only include the site origin" if uri.query.present? || uri.fragment.present?

      "#{uri.scheme}://#{uri.host}#{uri.port == uri.default_port ? '' : ":#{uri.port}"}"
    rescue URI::InvalidURIError => e
      raise ConfigurationError, "Project Gutenberg URL is invalid: #{e.message}"
    end

    def search_limit(limit)
      requested = limit || SettingsService.get(:gutenberg_search_limit, default: 10)
      requested.to_i.clamp(1, 25)
    end

    def parse_search_entries(body)
      doc = parse_xml(body)
      doc.xpath("//entry").filter_map do |entry|
        href = entry.at_xpath("./link[@rel='subsection']/@href")&.value.presence || entry.at_xpath("./id")&.text
        id = extract_book_id(href)
        next if id.blank?

        { id: id, path: book_opds_path(href, id) }
      end.uniq { |entry| entry[:id] }
    end

    def fetch_book_result(entry, requested_language:)
      response = connection.get(entry[:path])
      return nil if response.status == 404
      raise ConnectionError, "Project Gutenberg detail lookup failed with status #{response.status}" unless response.status == 200

      parse_book_result(response.body, fallback_id: entry[:id], requested_language: requested_language)
    end

    def parse_book_result(body, fallback_id:, requested_language:)
      entries = parse_xml(body).xpath("//entry")
      candidates = entries.filter_map do |entry|
        language = language_code(entry.at_xpath("./language")&.text)
        next if requested_language.present? && language.present? && language != requested_language

        format = preferred_download_format(entry.xpath("./link[contains(@rel, 'opds-spec.org/acquisition')]"))
        next unless format

        {
          entry: entry,
          format: format,
          language: language
        }
      end

      best = candidates.max_by { |candidate| candidate[:format][:score] }
      return nil unless best

      build_result(best[:entry], best[:format], fallback_id: fallback_id, language: best[:language])
    end

    def parse_xml(body)
      Nokogiri::XML(body) { |config| config.nonet }.tap(&:remove_namespaces!)
    end

    def build_result(entry, format, fallback_id:, language:)
      id = extract_book_id(entry.at_xpath("./id")&.text) || fallback_id
      Result.new(
        id: id,
        title: entry.at_xpath("./title")&.text.to_s.strip,
        author: entry.at_xpath("./author/name")&.text.to_s.strip.presence,
        language: language,
        year: nil,
        file_type: format[:file_type],
        download_url: normalize_download_url(format[:url]),
        info_url: id.present? ? "https://www.gutenberg.org/ebooks/#{id}" : nil
      )
    end

    def preferred_download_format(links)
      links.filter_map do |link|
        download_candidate(link)
      end.max_by { |candidate| candidate[:score] }
    end

    def download_candidate(link)
      mime_type = link["type"].to_s.split(";").first
      href = link["href"].to_s.strip
      return nil if href.blank?

      title = link["title"].to_s
      score = case mime_type
      when "application/epub+zip"
        300
      when "application/x-mobipocket-ebook"
        200
      when "application/pdf"
        100
      end
      return nil unless score

      score += 40 if title.match?(/EPUB3/i)
      score += 30 if title.match?(/images/i) && !title.match?(/no images/i)
      score += 10 if title.match?(/\AKindle\z/i)

      {
        file_type: file_type_for_mime_type(mime_type),
        url: href,
        score: score
      }
    end

    def file_type_for_mime_type(mime_type)
      case mime_type
      when "application/epub+zip"
        "epub"
      when "application/x-mobipocket-ebook"
        "mobi"
      when "application/pdf"
        "pdf"
      end
    end

    def extract_book_id(value)
      value.to_s[/ebooks\/(\d+)/, 1] || value.to_s[/urn:gutenberg:(\d+)/, 1]
    end

    def book_opds_path(href, id)
      uri = URI.join(base_url, href.to_s.presence || "/ebooks/#{id}.opds")
      uri.request_uri
    end

    def language_code(language)
      code = language.to_s.strip.downcase
      return nil if code.blank?

      code
    end

    def normalize_download_url(url)
      URI.join(base_url, url.to_s.strip.gsub(" ", "%20")).to_s
    end
  end
end
