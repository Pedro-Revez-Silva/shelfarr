# frozen_string_literal: true

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
      end

      def normalize_base_url(url)
        value = url.to_s.strip
        value.end_with?("/") ? value : "#{value}/"
      end
    end
  end
end
