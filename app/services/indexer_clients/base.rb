# frozen_string_literal: true

require "uri"

module IndexerClients
  class Base
    class Error < StandardError; end
    class ConnectionError < Error; end
    class AuthenticationError < Error; end
    class NotConfiguredError < Error; end

    CATEGORIES = {
      audiobook: [3030],
      ebook: [7020, 7000],
      all_books: [3030, 7020, 7000]
    }.freeze

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

      private

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

      def ensure_configured!
        raise NotConfiguredError, "#{display_name} is not configured" unless configured?
      end

      def request
        yield
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
        raise ConnectionError, "Failed to connect to #{display_name}: #{e.message}"
      rescue URI::Error, ArgumentError => e
        raise ConnectionError, "Invalid #{display_name} URL: #{e.message}"
      end

      def normalize_base_url(url)
        value = url.to_s.strip
        raise ArgumentError, "#{display_name} URL is blank" if value.blank?

        uri = URI.parse(value)
        unless %w[http https].include?(uri.scheme) && uri.host.present?
          raise ArgumentError, "#{display_name} URL must be a valid http or https URL"
        end

        normalized = uri.to_s
        normalized.end_with?("/") ? normalized : "#{normalized}/"
      rescue URI::InvalidURIError => e
        raise ArgumentError, "Invalid #{display_name} URL: #{e.message}"
      end
    end
  end
end
