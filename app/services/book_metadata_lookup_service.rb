# frozen_string_literal: true

require "set"

class BookMetadataLookupService
  MAX_WORK_ID_BYTES = 255
  ESSENTIAL_FIELDS = %i[title author description].freeze
  FIELD_READERS = {
    title: :title,
    author: :author,
    cover_url: :cover_url,
    year: :year,
    description: :description,
    publisher: :publisher,
    content_kind: :content_kind,
    issue_number: :issue_number,
    release_date: :release_date,
    series: :series_name,
    series_position: :series_position,
    collection_id: :collection_id,
    collection_title: :collection_title
  }.freeze

  class << self
    def call(work_ids, fallback: {})
      work_ids = normalize_work_ids(work_ids)
      return {} if work_ids.empty?

      metadata = {}
      merge_details!(metadata, fetch_details(work_ids.first), work_ids.first)
      return metadata if work_ids.one? || essential_metadata_complete?(metadata, fallback)

      work_ids.drop(1).zip(fetch_concurrently(work_ids.drop(1))).each do |work_id, details|
        merge_details!(metadata, details, work_id)
      end
      metadata
    end

    def normalize_work_ids(work_ids)
      seen_sources = Set.new

      Array(work_ids).compact_blank.filter_map do |work_id|
        work_id = work_id.to_s
        next if work_id.bytesize > MAX_WORK_ID_BYTES

        source, source_id = Book.parse_work_id(work_id)
        next unless MetadataSources::NAMES.key?(source) && source_id.present?
        next if seen_sources.include?(source)

        seen_sources << source
        "#{source}:#{source_id}"
      end
    end

    private

    def fetch_concurrently(work_ids)
      work_ids.map do |work_id|
        Thread.new do
          Rails.application.executor.wrap do
            ActiveRecord::Base.connection_pool.with_connection { fetch_details(work_id) }
          end
        end
      end.map(&:value)
    end

    def fetch_details(work_id)
      MetadataService.book_details(work_id)
    rescue *metadata_lookup_errors => e
      Rails.logger.warn("[BookMetadataLookupService] Metadata lookup failed for #{work_id}: #{e.message}")
      nil
    end

    def merge_details!(metadata, details, work_id)
      return unless details

      FIELD_READERS.each do |field, reader|
        next unless details.respond_to?(reader)

        metadata[field] ||= details.public_send(reader).presence
      end

      merge_provider_collection!(metadata, details, work_id)
    end

    def essential_metadata_complete?(metadata, fallback)
      fallback = fallback.to_h.symbolize_keys
      ESSENTIAL_FIELDS.all? { |field| metadata[field].present? || fallback[field].present? }
    end

    def merge_provider_collection!(metadata, details, work_id)
      source, = Book.parse_work_id(work_id)
      collection_id = if details.respond_to?(:collection_id)
        details.collection_id
      elsif details.respond_to?(:series_id)
        details.series_id
      end
      collection_title = if details.respond_to?(:collection_title)
        details.collection_title
      elsif details.respond_to?(:series_name)
        details.series_name
      end
      return if collection_id.blank? || collection_title.blank?

      metadata[:collection_source] ||= source
      metadata[:collection_id] ||= collection_id
      metadata[:collection_title] ||= collection_title
    end

    def metadata_lookup_errors
      errors = [ HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, ComicVineClient::Error, MetadataService::Error, ArgumentError ]
      errors << VCR::Errors::UnhandledHTTPRequestError if defined?(VCR::Errors::UnhandledHTTPRequestError)
      errors << WebMock::NetConnectNotAllowedError if defined?(WebMock::NetConnectNotAllowedError)
      errors
    end
  end
end
