# frozen_string_literal: true

class SearchResult < ApplicationRecord
  belongs_to :request

  after_commit :broadcast_request_show_refresh_later

  enum :status, {
    pending: 0,
    selected: 1,
    rejected: 2
  }

  # Source constants
  SOURCE_PROWLARR = "prowlarr"
  SOURCE_JACKETT = "jackett"
  SOURCE_ANNA_ARCHIVE = "anna_archive"
  SOURCE_ZLIBRARY = "zlibrary"

  validates :guid, presence: true, uniqueness: { scope: :request_id }
  validates :title, presence: true

  scope :selectable, -> { pending }

  scope :preferred_first, -> {
    ordered_types = SettingsService.preferred_download_types
    type_order_sql = ordered_types.each_with_index.map { |type, index| "WHEN '#{type}' THEN #{index}" }.join(" ")
    download_type_sql = <<~SQL.squish
      CASE
        WHEN source IN ('#{SOURCE_ANNA_ARCHIVE}', '#{SOURCE_ZLIBRARY}') THEN 'direct'
        WHEN download_url IS NOT NULL AND magnet_url IS NULL AND seeders IS NULL THEN 'usenet'
        ELSE 'torrent'
      END
    SQL

    order(Arel.sql("CASE #{download_type_sql} #{type_order_sql} ELSE #{ordered_types.length} END"))
  }

  scope :best_first, -> { preferred_first.order(confidence_score: :desc, seeders: :desc, size_bytes: :asc) }

  scope :high_confidence, ->(threshold = nil) {
    min_score = threshold || SettingsService.get(:min_match_confidence)
    where("confidence_score >= ?", min_score)
  }

  scope :matches_language, ->(lang) {
    where(detected_language: [ lang, nil ])
  }

  scope :auto_selectable, ->(threshold = nil) {
    min_score = threshold || SettingsService.get(:auto_select_confidence_threshold)
    high_confidence(min_score)
  }

  def downloadable?
    return true if direct_download?

    download_url.present? || magnet_url.present?
  end

  def download_link
    magnet_url.presence || download_url
  end

  # Check if this is a usenet/NZB result
  # Usenet results have: download URL, no magnet URL, no seeders
  # Torrent results have: magnet URL or seeders count
  def usenet?
    download_url.present? && magnet_url.blank? && seeders.nil?
  end

  # Check if this is a torrent result
  def torrent?
    magnet_url.present? || (download_url.present? && !usenet?)
  end

  def direct_download?
    from_anna_archive? || from_zlibrary?
  end

  def download_type
    return "direct" if direct_download?
    return "usenet" if usenet?
    return "torrent" if torrent?

    nil
  end

  def size_human
    return nil unless size_bytes

    ActiveSupport::NumberHelper.number_to_human_size(size_bytes)
  end

  def calculate_score!
    return unless request

    result = ReleaseScorer.score(self, request)
    update!(
      detected_language: result.detected_languages.first,
      confidence_score: result.total,
      score_breakdown: result.breakdown
    )
    result
  end

  def language_display_name
    return nil unless detected_language

    info = ReleaseParserService.language_info(detected_language)
    info ? info[:name] : detected_language
  end

  def language_flag
    return nil unless detected_language

    info = ReleaseParserService.language_info(detected_language)
    info&.dig(:flag)
  end

  def language_matches_request?
    return true if detected_language.blank?

    requested = request&.effective_language
    return true if requested.blank?

    detected_language == requested
  end

  def high_confidence?
    return false unless confidence_score

    confidence_score >= SettingsService.get(:auto_select_confidence_threshold)
  end

  def confidence_level
    return :unknown unless confidence_score

    if confidence_score >= 90
      :high
    elsif confidence_score >= 70
      :medium
    else
      :low
    end
  end

  def primary_extension
    score_detail(:extension).presence
  end

  def detected_extensions
    Array(score_detail(:extensions)).map(&:to_s)
  end

  def audiobook_structure
    structure = score_detail(:audiobook_structure)
    structure&.to_sym
  end

  def audio_bitrate_kbps
    bitrate = score_detail(:audio_bitrate_kbps)
    bitrate.present? ? bitrate.to_i : nil
  end

  def auto_select_allowed_by_preferences?
    auto_select_allowed = score_detail(:auto_select_allowed)
    return auto_select_allowed unless auto_select_allowed.nil?

    FormatPreferenceService.evaluate(title: title, book_type: request&.book&.book_type).auto_select_allowed
  end

  def preference_adjustment
    score_detail(:preference_adjustment).to_i
  end

  # Source helpers
  def from_prowlarr?
    source == SOURCE_PROWLARR || source.blank?
  end

  def from_jackett?
    source == SOURCE_JACKETT
  end

  def from_indexer?
    from_prowlarr? || from_jackett?
  end

  def from_anna_archive?
    source == SOURCE_ANNA_ARCHIVE
  end

  def from_zlibrary?
    source == SOURCE_ZLIBRARY
  end

  def source_display_name
    case source
    when SOURCE_JACKETT
      indexer.presence || "Jackett"
    when SOURCE_ANNA_ARCHIVE
      "Anna's Archive"
    when SOURCE_ZLIBRARY
      "Z-Library"
    else
      indexer.presence || "Prowlarr"
    end
  end

  private

  def score_detail(key)
    return nil unless score_breakdown.is_a?(Hash)

    return score_breakdown[key.to_s] if score_breakdown.key?(key.to_s)
    return score_breakdown[key.to_sym] if score_breakdown.key?(key.to_sym)

    nil
  end

  def broadcast_request_show_refresh_later
    Request.find_by(id: request_id)&.broadcast_show_refresh_later
  end
  private :broadcast_request_show_refresh_later
end
