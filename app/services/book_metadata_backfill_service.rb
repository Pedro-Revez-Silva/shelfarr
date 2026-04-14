# frozen_string_literal: true

# Fills in missing book metadata from the configured metadata provider
# without overwriting values that are already present.
class BookMetadataBackfillService
  class << self
    def apply!(book, work_id:, fallback_attrs: {})
      details = fetch_details(work_id)
      attrs = attributes_for(book, work_id, details, fallback_attrs)
      return false if attrs.empty?

      book.assign_attributes(attrs)
      book.save! if book.changed?
      book.saved_changes?
    end

    private

    def attributes_for(book, work_id, details, fallback_attrs)
      source, _source_id = Book.parse_work_id(work_id)

      attrs = {
        title: value_for(book.title, details&.title, fallback_attrs[:title]),
        author: value_for(book.author, details&.author, fallback_attrs[:author]),
        cover_url: value_for(book.cover_url, details&.cover_url, fallback_attrs[:cover_url]),
        year: numeric_value_for(book.year, details&.year, fallback_attrs[:year]),
        description: value_for(book.description, details&.description, fallback_attrs[:description]),
        series: value_for(book.series, details&.series_name, fallback_attrs[:series]),
        series_position: value_for(book.series_position, details&.series_position, fallback_attrs[:series_position])
      }.compact

      attrs[:metadata_source] = source if book.metadata_source.blank? || book.new_record?
      attrs
    end

    def value_for(current_value, detail_value, fallback_value = nil)
      return nil if current_value.present?

      detail_value.presence || fallback_value.presence
    end

    def numeric_value_for(current_value, detail_value, fallback_value = nil)
      return nil if current_value.present?

      detail_value || fallback_value
    end

    def fetch_details(work_id)
      MetadataService.book_details(work_id)
    rescue *metadata_lookup_errors => e
      Rails.logger.warn("[BookMetadataBackfillService] Metadata lookup failed for #{work_id}: #{e.message}")
      nil
    end

    def metadata_lookup_errors
      errors = [ HardcoverClient::Error, OpenLibraryClient::Error, MetadataService::Error, ArgumentError ]
      errors << VCR::Errors::UnhandledHTTPRequestError if defined?(VCR::Errors::UnhandledHTTPRequestError)
      errors << WebMock::NetConnectNotAllowedError if defined?(WebMock::NetConnectNotAllowedError)
      errors
    end
  end
end
