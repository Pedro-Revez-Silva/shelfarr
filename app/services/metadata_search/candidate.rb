# frozen_string_literal: true

module MetadataSearch
  class Candidate
    attr_reader :canonical_key, :title, :author, :year, :description, :cover_url,
      :series_name, :series_position, :has_ebook, :has_audiobook,
      :sources, :editions, :confidence, :content_kind, :available_book_types,
      :resource_kind, :classification_evidence, :classification_confidence, :categories, :subjects,
      :collection_source, :collection_id, :collection_title, :issue_number,
      :release_date

    def initialize(canonical_key:, title:, author:, year:, description:, cover_url:,
      series_name:, series_position:, has_ebook:, has_audiobook:, sources:, editions:, confidence:,
      content_kind: "book", available_book_types: nil, collection_source: nil, collection_id: nil,
      collection_title: nil, issue_number: nil, release_date: nil, resource_kind: "work",
      classification_evidence: [], classification_confidence: 0, categories: [], subjects: [])
      @canonical_key = canonical_key
      @title = title
      @author = author
      @year = year
      @description = description
      @cover_url = cover_url
      @series_name = series_name
      @series_position = series_position
      @has_ebook = has_ebook
      @has_audiobook = has_audiobook
      @sources = Array(sources)
      @editions = Array(editions)
      @confidence = confidence
      @content_kind = ContentKinds.normalize(content_kind)
      @available_book_types = RequestOptionPolicy.book_types_for(@content_kind)
      @resource_kind = resource_kind.to_s.presence || "work"
      @classification_evidence = Array(classification_evidence).compact_blank.freeze
      @classification_confidence = classification_confidence.to_i.clamp(0, 100)
      @categories = Array(categories).compact_blank.freeze
      @subjects = Array(subjects).compact_blank.freeze
      @collection_source = collection_source
      @collection_id = collection_id
      @collection_title = collection_title
      @issue_number = issue_number
      @release_date = release_date
    end

    def source
      primary_source&.fetch(:source, nil)
    end

    def source_id
      primary_source&.fetch(:source_id, nil)
    end

    def work_id
      primary_source&.fetch(:work_id, nil) || canonical_key
    end

    def first_publish_year
      year
    end

    def cover_id
      nil
    end

    def source_name
      primary_source&.fetch(:source_name, nil) || source.to_s.titleize
    end

    def source_url
      primary_source&.fetch(:source_url, nil)
    end

    def source_attribution
      "Metadata from #{source_name}"
    end

    def google_books?
      sources.any? { |source| source[:source] == "google_books" }
    end

    def graphic?
      content_kind == ContentKinds::GRAPHIC
    end

    def collection?
      collection_id.present? && collection_title.present?
    end

    def primary_source
      sources.first
    end
  end
end
