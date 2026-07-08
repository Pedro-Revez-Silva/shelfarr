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
        when "comic_vine"
          comic_vine(result)
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
          raw_payload: nil,
          content_kind: "book",
          available_book_types: %w[audiobook ebook],
          collection_source: nil,
          collection_id: nil,
          collection_title: nil,
          issue_number: nil,
          release_date: nil
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
          raw_payload: nil,
          content_kind: "book",
          available_book_types: %w[audiobook ebook],
          collection_source: nil,
          collection_id: nil,
          collection_title: nil,
          issue_number: nil,
          release_date: nil
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
          raw_payload: nil,
          content_kind: "book",
          available_book_types: %w[audiobook ebook],
          collection_source: nil,
          collection_id: nil,
          collection_title: nil,
          issue_number: nil,
          release_date: nil
        )
      end

      def comic_vine(result)
        ProviderResult.new(
          source: "comic_vine",
          source_id: result.resource_key,
          title: result.title,
          author: result.creators,
          year: result.year,
          description: truncate_description(result.description),
          cover_url: result.cover_url,
          isbn_10: nil,
          isbn_13: nil,
          publisher: result.publisher,
          page_count: nil,
          language: nil,
          series_name: result.series_name,
          series_position: result.issue_number,
          has_ebook: false,
          has_audiobook: false,
          source_url: result.web_url,
          raw_payload: result.raw_payload,
          content_kind: result.content_kind,
          available_book_types: [ "comicbook" ],
          collection_source: "comic_vine",
          collection_id: result.collection_id,
          collection_title: result.collection_title,
          issue_number: result.issue_number,
          release_date: result.release_date
        )
      end

      def truncate_description(desc)
        return nil if desc.blank?

        desc.length > 500 ? "#{desc[0, 497]}..." : desc
      end
    end
  end
end
