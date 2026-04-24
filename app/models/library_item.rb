# frozen_string_literal: true

class LibraryItem < ApplicationRecord
  validates :library_id, presence: true
  validates :audiobookshelf_id, presence: true
  validates :library_id, uniqueness: { scope: :audiobookshelf_id }

  scope :by_synced_at_desc, -> { order(synced_at: :desc, title: :asc) }
  scope :for_libraries, ->(ids) { where(library_id: ids) }
  scope :available_for_matching, -> { where.not(missing: true) }

  def audiobookshelf_url
    base_url = SettingsService.get(:audiobookshelf_url)
    return nil if base_url.blank? || audiobookshelf_id.blank?

    "#{base_url.to_s.chomp("/")}/item/#{audiobookshelf_id}"
  end

  def display_title
    [ title, subtitle.presence ].compact.join(": ")
  end

  def series_label
    return nil if series.blank?
    return series if series_position.blank?

    "#{series} ##{series_position}"
  end

  def detail_badges
    [
      published_year,
      series_label,
      narrator.present? ? "Narrated by #{narrator}" : nil,
      publisher.presence,
      language.present? ? language.upcase : nil
    ].compact
  end

  def identifier_label
    return "ISBN #{isbn}" if isbn.present?
    return "ASIN #{asin}" if asin.present?

    nil
  end

  def sync_stale?(threshold:)
    synced_at.blank? || synced_at < threshold
  end
end
