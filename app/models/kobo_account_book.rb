# frozen_string_literal: true

class KoboAccountBook < ApplicationRecord
  belongs_to :kobo_account
  validates :entitlement_id, presence: true, uniqueness: { scope: :kobo_account_id }
  validates :title, presence: true, length: { maximum: 4096 }
  validates :media_type, inclusion: { in: %w[ebook audiobook unknown] }
  validates :ownership_type, inclusion: { in: %w[purchased subscription preview unknown] }
end
