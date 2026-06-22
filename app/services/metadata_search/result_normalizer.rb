# frozen_string_literal: true

module MetadataSearch
  class ResultNormalizer
    class << self
      def call(source, result)
        case source.to_s
        when "hardcover"
          hardcover(result)
        when "google_books"
          google_books(result)
        when "openlibrary"
          openlibrary(result)
        else
          raise ArgumentError, "Unknown metadata source: #{source}"
        end
      end

      private

      def hardcover(result)
        ProviderResult.new(
          source: "hardcover",
          source_id: result.id.to_s,
          title: result.title,
          author: result.author,
          year: result.release_year,
          description: truncate_description(result.description),
          cover_url: result.cover_url,
          isbn_10: nil,
          isbn_13: nil,
          publisher: nil,
          page_count: nil,
          language: nil,
          series_name: result.series_name,
          series_position: result.series_position,
          has_ebook: result.has_ebook,
          has_audiobook: result.has_audiobook,
          source_url: "https://hardcover.app/books/#{result.id}",
          raw_payload: nil
        )
      end

      def google_books(result)
        ProviderResult.new(
          source: "google_books",
          source_id: result.id,
          title: result.title,
          author: result.author,
          year: result.first_publish_year,
          description: truncate_description(result.description),
          cover_url: result.cover_url,
          isbn_10: result.respond_to?(:isbn_10) ? result.isbn_10 : nil,
          isbn_13: result.respond_to?(:isbn_13) ? result.isbn_13 : nil,
          publisher: result.respond_to?(:publisher) ? result.publisher : nil,
          page_count: result.respond_to?(:page_count) ? result.page_count : nil,
          language: result.language,
          series_name: nil,
          series_position: nil,
          has_ebook: result.has_ebook,
          has_audiobook: nil,
          source_url: result.respond_to?(:source_url) ? result.source_url : "https://books.google.com/books?id=#{result.id}",
          raw_payload: nil
        )
      end

      def openlibrary(result)
        ProviderResult.new(
          source: "openlibrary",
          source_id: result.work_id,
          title: result.title,
          author: result.author,
          year: result.first_publish_year,
          description: nil,
          cover_url: result.cover_url(size: :l),
          isbn_10: nil,
          isbn_13: nil,
          publisher: nil,
          page_count: nil,
          language: nil,
          series_name: nil,
          series_position: nil,
          has_ebook: nil,
          has_audiobook: nil,
          source_url: "https://openlibrary.org/works/#{result.work_id}",
          raw_payload: nil
        )
      end

      def truncate_description(desc)
        return nil if desc.blank?

        desc.length > 500 ? "#{desc[0, 497]}..." : desc
      end
    end
  end
end
