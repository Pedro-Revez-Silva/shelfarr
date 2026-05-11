# frozen_string_literal: true

class TelegramUpdate < ApplicationRecord
  validates :update_id, presence: true, uniqueness: true

  scope :recent_for_user, ->(telegram_user_id, since:) {
    where(telegram_user_id: telegram_user_id.to_s)
      .where("created_at >= ?", since)
  }
end
