# frozen_string_literal: true

# Fills in missing book metadata from the configured metadata provider
# without overwriting values that are already present.
class BookMetadataBackfillService
  class << self
    def apply!(book, work_id:, fallback_attrs: {}, lookup_details: true)
      details = lookup_details ? fetch_details(work_id) : nil
      attrs = attributes_for(book, work_id, details, fallback_attrs)
      book.assign_attributes(attrs) unless attrs.empty?
      return false unless book.changed?

      book.save!
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
        series_position: value_for(book.series_position, details&.series_position, fallback_attrs[:series_position]),
        publisher: value_for(book.publisher, detail_value(details, :publisher), fallback_attrs[:publisher]),
        content_kind: content_kind_value_for(book, detail_value(details, :content_kind), fallback_attrs[:content_kind]),
        issue_number: value_for(book.issue_number, detail_value(details, :issue_number), fallback_attrs[:issue_number]),
        release_date: value_for(book.release_date, detail_value(details, :release_date), fallback_attrs[:release_date])
      }.compact

      attrs[:metadata_source] = source if book.metadata_source.blank? || book.new_record?
      attrs
    end

    def value_for(current_value, detail_value, fallback_value = nil)
      return nil if current_value.present?

      detail_value.presence || fallback_value.presence
    end

    def detail_value(details, field)
      details.public_send(field) if details.respond_to?(field)
    end

    def numeric_value_for(current_value, detail_value, fallback_value = nil)
      return nil if current_value.present?

      detail_value || fallback_value
    end

    def content_kind_value_for(book, detail_value, fallback_value = nil)
      value = detail_value.presence || fallback_value.presence
      return nil if value.blank?

      value = ContentKinds.normalize(value, default: "book")
      return nil if !book.new_record? && book.content_kind.present? && !book.content_book?

      value
    end

    def fetch_details(work_id)
      MetadataService.book_details(work_id)
    rescue *metadata_lookup_errors => e
      Rails.logger.warn("[BookMetadataBackfillService] Metadata lookup failed for #{work_id}: #{e.message}")
      nil
    end

    def metadata_lookup_errors
      errors = [ HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, ComicVineClient::Error, MetadataService::Error, ArgumentError ]
      errors << VCR::Errors::UnhandledHTTPRequestError if defined?(VCR::Errors::UnhandledHTTPRequestError)
      errors << WebMock::NetConnectNotAllowedError if defined?(WebMock::NetConnectNotAllowedError)
      errors
    end
  end
end
