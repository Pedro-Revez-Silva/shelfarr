# frozen_string_literal: true

module MetadataSearch
  ProviderResult = Data.define(
    :source, :source_id, :title, :author, :year, :description, :cover_url,
    :isbn_10, :isbn_13, :publisher, :page_count, :language,
    :series_name, :series_position, :has_ebook, :has_audiobook,
    :source_url, :raw_payload
  ) do
    SOURCE_NAMES = {
      "hardcover" => "Hardcover",
      "google_books" => "Google Books",
      "openlibrary" => "Open Library"
    }.freeze

    def work_id
      "#{source}:#{source_id}"
    end

    def source_name
      SOURCE_NAMES.fetch(source.to_s, source.to_s.titleize)
    end

    def source_attribution
      "Metadata from #{source_name}"
    end
  end
end
