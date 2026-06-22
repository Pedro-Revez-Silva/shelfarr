# frozen_string_literal: true

module MetadataSearch
  ProviderResult = Data.define(
    :source, :source_id, :title, :author, :year, :description, :cover_url,
    :isbn_10, :isbn_13, :publisher, :page_count, :language,
    :series_name, :series_position, :has_ebook, :has_audiobook,
    :source_url, :raw_payload
  ) do
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
