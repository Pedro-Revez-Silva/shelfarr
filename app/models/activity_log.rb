# frozen_string_literal: true

class ActivityLog < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :trackable, polymorphic: true, optional: true

  ACTIONS = %w[
    user.login user.logout user.created
    request.created request.cancelled request.completed request.failed
    download.started download.completed download.failed
    upload.created upload.processed upload.failed
    settings.updated
    admin.user_created admin.user_updated admin.user_deleted
  ].freeze
  LIST_LIMIT = 100

  validates :action, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :for_action, ->(action) { where(action: action) }
  scope :by_user, ->(user) { where(user: user) }
  scope :for_trackable, ->(obj) { where(trackable: obj) }

  def self.listing(user_id: nil, action: nil, from: nil)
    logs = recent
    logs = logs.by_user(user_id) if user_id.present?
    logs = logs.for_action(action) if action.present?
    logs = logs.where("created_at >= ?", from) if from.present?
    logs
  end

  def self.track(action:, user: nil, trackable: nil, details: {}, ip_address: nil, controller: nil)
    create!(
      action: action,
      user: user,
      trackable: trackable,
      details: details,
      ip_address: ip_address,
      controller: controller
    )
  rescue => e
    Rails.logger.error "[ActivityLog] Failed to log: #{e.message}"
    nil
  end
end
