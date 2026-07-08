# frozen_string_literal: true

module MetadataSearch
  class ProviderResult
    DEFAULTS = {
      isbn_10: nil,
      isbn_13: nil,
      publisher: nil,
      page_count: nil,
      language: nil,
      series_name: nil,
      series_position: nil,
      has_ebook: nil,
      has_audiobook: nil,
      source_url: nil,
      raw_payload: nil,
      content_kind: "book",
      available_book_types: nil,
      collection_source: nil,
      collection_id: nil,
      collection_title: nil,
      issue_number: nil,
      release_date: nil
    }.freeze

    attr_reader :source, :source_id, :title, :author, :year, :description, :cover_url,
      :isbn_10, :isbn_13, :publisher, :page_count, :language,
      :series_name, :series_position, :has_ebook, :has_audiobook,
      :source_url, :raw_payload, :content_kind, :available_book_types,
      :collection_source, :collection_id, :collection_title, :issue_number,
      :release_date

    def initialize(**attributes)
      DEFAULTS.merge(attributes).each do |key, value|
        instance_variable_set("@#{key}", value)
      end
    end

    def work_id
      "#{source}:#{source_id}"
    end

    def source_name
      MetadataSources.display_name(source)
    end

    def source_attribution
      "Metadata from #{source_name}"
    end
  end
end
