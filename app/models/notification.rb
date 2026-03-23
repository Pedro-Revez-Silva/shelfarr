# frozen_string_literal: true

class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :notifiable, polymorphic: true, optional: true

  TYPES = %w[request_completed request_failed request_attention request_created].freeze

  validates :notification_type, presence: true, inclusion: { in: TYPES }
  validates :title, presence: true

  scope :unread, -> { where(read_at: nil) }
  scope :recent, -> { order(created_at: :desc).limit(20) }

  def read?
    read_at.present?
  end

  def mark_as_read!
    update!(read_at: Time.current) unless read?
  end

  def self.mark_all_read!(user)
    user.notifications.unread.update_all(read_at: Time.current)
  end
end
