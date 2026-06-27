# frozen_string_literal: true

class LibraryItem < ApplicationRecord
  validates :library_platform, presence: true, inclusion: { in: SettingsService::LIBRARY_PLATFORMS }
  validates :library_id, presence: true
  validates :audiobookshelf_id, presence: true
  validates :library_id, uniqueness: { scope: [ :library_platform, :audiobookshelf_id ] }

  scope :by_synced_at_desc, -> { order(synced_at: :desc, title: :asc) }
  scope :for_platform, ->(platform) { where(library_platform: platform) }
  scope :for_active_platform, -> { for_platform(SettingsService.active_library_platform) }
  scope :for_libraries, ->(ids) { where(library_id: ids) }
  scope :available_for_matching, -> { for_active_platform.where.not(missing: true) }

  def library_url
    LibraryPlatformClient.item_url(self)
  end

  def audiobookshelf_url
    library_url
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
