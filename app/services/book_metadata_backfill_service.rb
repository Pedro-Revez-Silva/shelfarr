# frozen_string_literal: true

# Fills in missing book metadata from the configured metadata provider
# without overwriting values that are already present.
class BookMetadataBackfillService
  class << self
    def apply!(book, work_id:, source_work_ids: [], fallback_attrs: {}, lookup_details: true)
      metadata = if lookup_details
        BookMetadataLookupService.call(
          [ work_id, *Array(source_work_ids) ],
          fallback: fallback_attrs
        )
      else
        {}
      end
      attrs = attributes_for(book, work_id, metadata, fallback_attrs)
      book.assign_attributes(attrs) unless attrs.empty?
      return false unless book.changed?

      book.save!
      book.saved_changes?
    end

    private

    def attributes_for(book, work_id, metadata, fallback_attrs)
      source, _source_id = Book.parse_work_id(work_id)

      attrs = {
        title: value_for(book.title, metadata[:title], fallback_attrs[:title]),
        author: value_for(book.author, metadata[:author], fallback_attrs[:author]),
        cover_url: value_for(book.cover_url, metadata[:cover_url], fallback_attrs[:cover_url]),
        year: numeric_value_for(book.year, metadata[:year], fallback_attrs[:year]),
        description: value_for(book.description, metadata[:description], fallback_attrs[:description]),
        series: value_for(book.series, metadata[:series], fallback_attrs[:series]),
        series_position: value_for(book.series_position, metadata[:series_position], fallback_attrs[:series_position]),
        publisher: value_for(book.publisher, metadata[:publisher], fallback_attrs[:publisher]),
        content_kind: content_kind_value_for(book, metadata[:content_kind], fallback_attrs[:content_kind]),
        issue_number: value_for(book.issue_number, metadata[:issue_number], fallback_attrs[:issue_number]),
        release_date: value_for(book.release_date, metadata[:release_date], fallback_attrs[:release_date])
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

    def content_kind_value_for(book, detail_value, fallback_value = nil)
      value = detail_value.presence || fallback_value.presence
      return nil if value.blank?

      value = ContentKinds.normalize(value, default: "book")
      return nil if !book.new_record? && book.content_kind.present? && !book.content_book?

      value
    end
  end
end
