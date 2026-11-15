# frozen_string_literal: true

require "cgi"

module WebPreview
  class PublicationJson
    FIXED_LAYOUT_TYPES = %w[application/pdf image/jpeg image/png image/webp].freeze

    def initialize(book:, representation:, reader_path:, progress_label:, format_label:, cover_style:)
      @book = book
      @representation = representation
      @reader_path = reader_path
      @progress_label = progress_label
      @format_label = format_label
      @cover_style = cover_style
    end

    def summary
      assets = @representation.fetch(:assets)
      {
        id: @book.id.to_s,
        title: @book.title.to_s,
        author: @book.author.presence,
        book_type: @representation.fetch(:book_type),
        content_kind: @representation.fetch(:content_kind),
        format_label: @format_label,
        availability: assets.empty? ? "unavailable" : "available",
        action: @book.audiobook? ? "listen" : "read",
        cover: { url: @representation[:cover_url], style: @cover_style },
        reading_status: @representation.fetch(:reading_status),
        progress: progress(@representation[:progress]),
        progress_label: @progress_label,
        reader_url: @reader_path
      }
    end

    def detail
      summary.merge(
        description: plain_text(@representation[:description]),
        files: @representation.fetch(:assets).map { |asset| file(asset) }
      )
    end

    private

    def file(asset)
      { id: asset.fetch(:id), filename: asset.fetch(:filename), format: asset.fetch(:format), media_type: asset.fetch(:media_type),
        size_bytes: asset.fetch(:size_bytes), position: asset.fetch(:position), page_count: asset[:page_count] }
    end

    def progress(raw)
      return nil unless raw

      locator = raw[:locator].is_a?(Hash) ? raw[:locator] : {}
      locations = locator["locations"].is_a?(Hash) ? locator["locations"] : {}
      fixed = FIXED_LAYOUT_TYPES.include?(locator["type"])
      page = locations["position"]
      fraction = locations["totalProgression"]
      {
        asset_id: raw.fetch(:asset_id),
        position_seconds: raw[:position_seconds],
        fraction: fraction.is_a?(Numeric) ? fraction.to_f.clamp(0.0, 1.0) : nil,
        page: fixed && page.is_a?(Integer) && page.positive? ? page : nil,
        version: raw.fetch(:version),
        observed_at: raw[:observed_at],
        updated_at: raw.fetch(:updated_at)
      }
    end

    def plain_text(value)
      visible = value.to_s.gsub(%r{<(script|style)\b.*?</\1\s*>}mi, "")
      breaks = visible.gsub(%r{</?(?:p|div|li|br|h[1-6]|tr)\b[^>]*>}i, "\n")
      text = CGI.unescapeHTML(Rails::HTML5::FullSanitizer.new.sanitize(breaks).to_s)
      text.gsub(/[ \t]+/, " ").gsub(/ ?\n ?/, "\n").gsub(/\n{3,}/, "\n\n").strip
    end
  end
end
