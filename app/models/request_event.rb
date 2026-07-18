# frozen_string_literal: true

class RequestEvent < ApplicationRecord
  belongs_to :request
  belongs_to :download, optional: true

  after_commit :broadcast_request_show_refresh_later, on: [ :create, :update ]

  enum :level, {
    info: 0,
    warn: 1,
    error: 2
  }

  validates :event_type, presence: true
  validates :source, presence: true
  validates :level, presence: true

  scope :recent, -> { order(updated_at: :desc) }

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

  # Some diagnostics describe the request's current state rather than a new
  # occurrence. Refreshing that state should update one event instead of
  # filling the timeline with identical entries.
  def self.record_latest!(request:, event_type:, source:, message: nil, level: :info, download: nil, details: {}, user_visible: false)
    attempts = 0
    begin
      transaction do
        event = find_or_initialize_by(
          request: request,
          event_type: event_type,
          source: source
        )
        event.assign_attributes(
          download: download,
          message: message,
          level: level,
          details: details.compact,
          user_visible: user_visible
        )
        event.save!
        event
      end
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      retry if attempts == 1

      raise
    end
  rescue => e
    Rails.logger.error "[RequestEvent] Failed to record #{event_type}: #{e.message}"
    nil
  end

  def self.clear_latest!(request:, event_type:, source:)
    where(request: request, event_type: event_type, source: source).delete_all
  rescue => e
    Rails.logger.error "[RequestEvent] Failed to clear #{event_type}: #{e.message}"
    nil
  end

  private

  def broadcast_request_show_refresh_later
    Request.find_by(id: request_id)&.broadcast_show_refresh_later
  end
end
