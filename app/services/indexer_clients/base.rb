# frozen_string_literal: true

require "uri"

module IndexerClients
  class Base
    class Error < StandardError; end
    class ConnectionError < Error; end
    class AuthenticationError < Error; end
    class NotConfiguredError < Error; end
    class InvalidUrlError < Error; end

    class << self
      def search(...)
        raise NotImplementedError
      end

      def configured?
        raise NotImplementedError
      end

      def test_connection
        raise NotImplementedError
      end

      def reset_connection!
        @connection = nil
      end

      def display_name
        name.demodulize
      end

      def validate_url!(url)
        normalize_base_url(url)
        true
      end

      private

      def categories_for_type(book_type)
        SettingsService.indexer_category_ids_for(book_type)
      end

      def ensure_configured!
        raise NotConfiguredError, "#{display_name} is not configured" unless configured?
      end

      def request
        yield
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
        raise ConnectionError, "Failed to connect to #{display_name}: #{e.message}"
      rescue InvalidUrlError => e
        # Preserve connection-error classification for malformed stored URLs so
        # search/dispatch paths keep treating them like other connect failures.
        raise ConnectionError, e.message
      rescue URI::Error, ArgumentError => e
        raise ConnectionError, "Invalid #{display_name} URL: #{e.message}"
      end

      def normalize_base_url(url)
        value = url.to_s.strip
        raise InvalidUrlError, "#{display_name} URL is blank" if value.blank?

        uri = URI.parse(value)
        unless %w[http https].include?(uri.scheme) && uri.host.present?
          raise InvalidUrlError, "#{display_name} URL must be a valid http or https URL"
        end

        normalized = uri.to_s
        normalized.end_with?("/") ? normalized : "#{normalized}/"
      rescue URI::InvalidURIError => e
        raise InvalidUrlError, "Invalid #{display_name} URL: #{e.message}"
      end
    end
  end
end
