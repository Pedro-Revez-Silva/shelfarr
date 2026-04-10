# frozen_string_literal: true

module IndexerClients
  class Jackett < Base
    DEFAULT_INDEXER_FILTER = "all"

    class << self
      def search(query, categories: nil, book_type: nil, limit: 100, **)
        ensure_configured!

        params = {
          apikey: api_key,
          t: "search",
          q: query,
          limit: limit,
          offset: 0
        }

        cats = categories || categories_for_type(book_type)
        params[:cat] = Array(cats).join(",") if cats.present?

        response = request { connection.get(search_path, params) }
        handle_response(response) { |body| parse_results(body, limit: limit) }
      end

      def configured?
        SettingsService.jackett_configured?
      end

      def test_connection
        ensure_configured!

        response = connection.get(search_path, { apikey: api_key, t: "caps" })
        response.status == 200
      rescue IndexerClients::Base::Error, Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError
        false
      end

      def display_name
        "Jackett"
      end

      private

      def connection
        @connection ||= Faraday.new(url: base_url) do |f|
          f.request :url_encoded
          f.adapter Faraday.default_adapter
          f.options.timeout = 30
          f.options.open_timeout = 10
        end
      end

      def base_url
        normalize_base_url(SettingsService.get(:jackett_url))
      end

      def api_key
        SettingsService.get(:jackett_api_key)
      end

      def indexer_filter
        SettingsService.get(:jackett_indexer_filter).to_s.strip.presence || DEFAULT_INDEXER_FILTER
      end

      def search_path
        "api/v2.0/indexers/#{indexer_filter}/results/torznab/api"
      end

      def handle_response(response)
        case response.status
        when 200
          yield response.body
        when 401, 403
          raise AuthenticationError, "Invalid Jackett API key"
        when 404
          raise Error, "Jackett endpoint not found"
        else
          raise Error, "Jackett API error: #{response.status}"
        end
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
        raise ConnectionError, "Failed to connect to Jackett: #{e.message}"
      end

      def parse_results(xml, limit:)
        require "nokogiri"

        doc = Nokogiri::XML(xml)
        doc.remove_namespaces!

        doc.xpath("//rss/channel/item").first(limit).map { |item| parse_item(item) }
      rescue Nokogiri::XML::SyntaxError => e
        raise Error, "Failed to parse Jackett response: #{e.message}"
      end

      def parse_item(item)
        enclosure = item.at_xpath("enclosure")
        enclosure_url = enclosure&.[]("url").to_s.strip.presence
        enclosure_length = enclosure&.[]("length")
        link = item.at_xpath("link")&.text.to_s.strip.presence
        attrs = item.xpath("attr").each_with_object({}) do |attr, lookup|
          lookup[attr["name"].to_s] = attr["value"]
        end

        Result.new(
          guid: item.at_xpath("guid")&.text.to_s.strip.presence || enclosure_url || link || SecureRandom.uuid,
          title: item.at_xpath("title")&.text.to_s.strip,
          indexer: item.at_xpath("jackettindexer")&.text.to_s.strip.presence || item.at_xpath("comments")&.text.to_s.strip.presence || "Jackett",
          size_bytes: integer_attr(enclosure_length) || integer_attr(item.at_xpath("size")&.text) || integer_attr(attrs["size"]),
          seeders: integer_attr(attrs["seeders"]),
          leechers: integer_attr(attrs["peers"]) || integer_attr(attrs["leechers"]),
          download_url: extract_download_url(enclosure_url),
          magnet_url: extract_magnet_url(enclosure_url),
          info_url: link,
          published_at: parse_date(item.at_xpath("pubDate")&.text)
        )
      end

      def integer_attr(value)
        return nil if value.blank?

        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end

      def extract_download_url(enclosure_url)
        return nil if enclosure_url.blank? || enclosure_url.start_with?("magnet:")

        enclosure_url
      end

      def extract_magnet_url(enclosure_url)
        return nil unless enclosure_url.present? && enclosure_url.start_with?("magnet:")

        enclosure_url
      end

      def parse_date(date_string)
        return nil if date_string.blank?

        Time.parse(date_string)
      rescue ArgumentError
        nil
      end
    end
  end
end
