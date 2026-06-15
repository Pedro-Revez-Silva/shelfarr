# frozen_string_literal: true

module IndexerClients
  class Newznab < Jackett
    class << self
      def configured?
        SettingsService.newznab_configured?
      end

      def display_name
        "Newznab"
      end

      private

      def base_url
        normalize_base_url(strip_api_path(SettingsService.get(:newznab_url)))
      end

      def api_key
        SettingsService.get(:newznab_api_key)
      end

      def search_path
        "api"
      end

      def indexer_name_for(_item, attrs)
        attrs["hydraIndexerName"].presence ||
          attrs["indexer"].presence ||
          attrs["provider"].presence ||
          "NZBHydra2 / Newznab"
      end

      def strip_api_path(url)
        value = url.to_s.strip
        uri = URI.parse(value)
        path = uri.path.to_s
        normalized_path = path.delete_suffix("/")

        if normalized_path.end_with?("/api")
          base_path = normalized_path.delete_suffix("/api")
          uri.path = base_path.presence || "/"
        end

        uri.to_s
      rescue URI::InvalidURIError
        value
      end
    end
  end
end
