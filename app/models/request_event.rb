# frozen_string_literal: true

class RequestEvent < ApplicationRecord
  belongs_to :request
  belongs_to :download, optional: true

  after_create_commit :broadcast_request_show_refresh_later

  enum :level, {
    info: 0,
    warn: 1,
    error: 2
  }

  validates :event_type, presence: true
  validates :source, presence: true
  validates :level, presence: true

  scope :recent, -> { order(created_at: :desc) }

  def self.record!(request:, event_type:, source:, message: nil, level: :info, download: nil, details: {}, user_visible: false)
    create!(
      request: request,
      download: download,
      event_type: event_type,
      source: source,
      message: message,
      level: level,
      details: details.compact,
      user_visible: user_visible
    )
  rescue => e
    Rails.logger.error "[RequestEvent] Failed to record #{event_type}: #{e.message}"
    nil
  end

  private

  def broadcast_request_show_refresh_later
    Request.find_by(id: request_id)&.broadcast_show_refresh_later
  end
end
