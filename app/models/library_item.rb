# frozen_string_literal: true

class LibraryItem < ApplicationRecord
  validates :library_id, presence: true
  validates :audiobookshelf_id, presence: true
  validates :library_id, uniqueness: { scope: :audiobookshelf_id }

  scope :by_synced_at_desc, -> { order(synced_at: :desc, title: :asc) }
  scope :for_libraries, ->(ids) { where(library_id: ids) }

  def audiobookshelf_url
    base_url = SettingsService.get(:audiobookshelf_url)
    return nil if base_url.blank? || audiobookshelf_id.blank?

    "#{base_url.to_s.chomp("/")}/item/#{audiobookshelf_id}"
  end

  def sync_stale?(threshold:)
    synced_at.blank? || synced_at < threshold
  end
end
