# frozen_string_literal: true

module MetadataSearch
  class Candidate
    attr_reader :canonical_key, :title, :author, :year, :description, :cover_url,
      :series_name, :series_position, :has_ebook, :has_audiobook,
      :sources, :editions, :confidence

    def initialize(canonical_key:, title:, author:, year:, description:, cover_url:,
      series_name:, series_position:, has_ebook:, has_audiobook:, sources:, editions:, confidence:)
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

    def primary_source
      sources.first
    end
  end
end
