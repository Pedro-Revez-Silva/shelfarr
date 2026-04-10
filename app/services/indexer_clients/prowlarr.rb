# frozen_string_literal: true

module IndexerClients
  class Prowlarr < Base
    Result = IndexerClients::Result

    class << self
      def search(query, categories: nil, book_type: nil, limit: 100, title: nil, author: nil)
        ensure_configured!

        params = {
          query: build_query(query, title: title, author: author),
          type: search_type_for(title: title, author: author),
          limit: limit
        }

        cats = categories || categories_for_type(book_type)
        params[:categories] = Array(cats) if cats.present?

        indexer_ids = filtered_indexer_ids
        params[:indexerIds] = indexer_ids if indexer_ids.present?

        response = request { connection.get("api/v1/search", params) }

        handle_response(response) do |data|
          Array(data).map { |item| parse_result(item) }
        end
      end

      def indexers
        ensure_configured!

        response = request { connection.get("api/v1/indexer") }
        handle_response(response) { |data| Array(data) }
      end

      def filtered_indexer_ids
        tags = indexer_filter_tags.map(&:to_s).map(&:downcase)
        return nil if tags.empty?

        indexers
          .select { |indexer| (normalized_indexer_tags(indexer["tags"]) & tags).any? }
          .map { |indexer| indexer["id"] }
      rescue IndexerClients::Base::Error => e
        Rails.logger.warn "[IndexerClients::Prowlarr] Failed to fetch indexers for tag filtering: #{e.message}"
        nil
      end

      def configured_tags
        tags_setting = SettingsService.get(:prowlarr_tags).to_s.strip
        return [] if tags_setting.blank?

        tags_setting.split(",").map { |tag| tag.strip.to_i }.reject(&:zero?)
      end

      def configured_tag_names
        tags_setting = SettingsService.get(:prowlarr_tags).to_s.strip
        return [] if tags_setting.blank?

        tags_setting.split(",").map(&:strip).reject do |tag|
          tag.blank? || tag.match?(/\A\d+\z/)
        end
      end

      def indexer_filter_tags
        configured_tags.concat(configured_tag_ids_for_names(configured_tag_names)).uniq
      end

      def configured?
        SettingsService.prowlarr_configured?
      end

      def test_connection
        ensure_configured!

        response = connection.get("api/v1/indexer")
        response.status == 200
      rescue IndexerClients::Base::Error, Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError
        false
      end

      def display_name
        "Prowlarr"
      end

      private

      def configured_tag_ids_for_names(tag_names)
        return [] if tag_names.empty?

        response = request { connection.get("api/v1/tag") }
        handle_response(response) do |tags|
          tag_lookup = {}

          Array(tags).each do |tag|
            next unless tag.is_a?(Hash)

            label = tag["label"] || tag["name"] || tag["tag"]
            tag_id = tag["id"] || tag["tagId"]
            next if label.blank? || tag_id.blank?

            tag_lookup[label.to_s.strip.downcase] = tag_id.to_i
          end

          tag_names.filter_map { |name| tag_lookup[name.to_s.downcase] }
        end
      rescue IndexerClients::Base::Error => e
        Rails.logger.warn "[IndexerClients::Prowlarr] Failed to resolve tag names for filtering: #{e.message}"
        []
      end

      def normalized_indexer_tags(tags)
        tags.to_a.flat_map do |tag|
          case tag
          when Hash
            [tag["id"], tag["label"], tag["name"]]
          else
            tag
          end
        end.compact.map(&:to_s).map(&:downcase)
      end

      def connection
        @connection ||= Faraday.new(url: base_url) do |f|
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
        normalize_base_url(SettingsService.get(:prowlarr_url))
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
        return nil if url.blank? || url.start_with?("magnet:")

        Rails.logger.debug "[IndexerClients::Prowlarr] Received download URL from indexer '#{item['indexer']}' (#{url.length} chars): #{url.truncate(100)}"
        url
      end

      def extract_magnet_url(item)
        magnet = item["magnetUrl"]
        return magnet if magnet.present?

        url = item["downloadUrl"]
        url if url.present? && url.start_with?("magnet:")
      end

      def parse_date(date_string)
        return nil if date_string.blank?

        Time.parse(date_string)
      rescue ArgumentError
        nil
      end

      def search_type_for(title:, author:)
        sanitized_book_value(title).present? || sanitized_book_value(author).present? ? "book" : "search"
      end

      def build_query(query, title:, author:)
        return query if search_type_for(title: title, author: author) == "search"

        parts = []
        sanitized_title = sanitized_book_value(title)
        sanitized_author = sanitized_book_value(author)

        parts << "{title:#{sanitized_title}}" if sanitized_title.present?
        parts << "{author:#{sanitized_author}}" if sanitized_author.present?
        parts << query if query.present?
        parts.join(" ")
      end

      def sanitized_book_value(value)
        value.to_s.tr("{}", "  ").squish.presence
      end
    end
  end
end
