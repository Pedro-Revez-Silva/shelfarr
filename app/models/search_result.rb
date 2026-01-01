# frozen_string_literal: true

class SearchResult < ApplicationRecord
  belongs_to :request

  enum :status, {
    pending: 0,
    selected: 1,
    rejected: 2
  }

  validates :guid, presence: true, uniqueness: { scope: :request_id }
  validates :title, presence: true

  scope :selectable, -> { pending }

  scope :preferred_first, -> {
    preferred = SettingsService.get(:preferred_download_type, default: "torrent")
    if preferred == "usenet"
      order(Arel.sql("CASE WHEN download_url IS NOT NULL AND magnet_url IS NULL AND seeders IS NULL THEN 0 ELSE 1 END"))
    else
      order(Arel.sql("CASE WHEN magnet_url IS NOT NULL THEN 0 ELSE 1 END"))
    end
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
end
