# frozen_string_literal: true

class KoboTag < ApplicationRecord
  MAX_PER_DEVICE = 100
  MAX_ITEMS = 1000
  REVISION_ID = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/
  ITEM_TYPE = /\A[A-Za-z]{1,64}\z/

  belongs_to :kobo_device

  validates :tag_id, presence: true
  validates :name, presence: true, length: { maximum: 255 }
  validates :items, length: { maximum: MAX_ITEMS }
  validate :within_reader_limit, on: :create

  def self.items_from(value)
    return unless value.is_a?(Array)

    items = value.map do |item|
      return unless item.is_a?(Hash) && item["RevisionId"].is_a?(String) && item["Type"].is_a?(String)
      return unless item["RevisionId"].match?(REVISION_ID) && item["Type"].match?(ITEM_TYPE)

      item.slice("RevisionId", "Type")
    end
    items.uniq
  end

  def sync_entry
    { "NewTag" => { "Tag" => { "Created" => created_at.utc.iso8601(3), "Id" => tag_id, "Items" => items,
      "LastModified" => updated_at.utc.iso8601(3), "Name" => name, "Type" => "UserTag" } } }
  end

  private

  def within_reader_limit
    errors.add(:base, "This reader already keeps #{MAX_PER_DEVICE} collections") if kobo_device.kobo_tags.count >= MAX_PER_DEVICE
  end
end
