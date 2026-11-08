# frozen_string_literal: true

# This connection belongs to one Shelfarr user. Catalogue records deliberately
# do not enter the shared Book library until a separate sharing/delivery flow
# exists. Authentication uses a virtual device, never the user's physical Kobo.
class KoboAccount < ApplicationRecord
  STATUSES = %w[pending connected expired failed reauthorization_required].freeze
  SYNC_STATUSES = %w[idle queued syncing].freeze
  PRIVATE_ATTRIBUTES = %i[device_id serial_number activation_poll_url activation_code
    kobo_user_id kobo_user_key kobo_email access_token refresh_token].freeze
  ERROR_MESSAGES = {
    "provider_unavailable" => "Kobo could not be reached. Try again shortly.",
    "protocol_changed" => "Kobo returned an unexpected response. Your saved connection and catalogue have been kept.",
    "activation_expired" => "This sign-in code expired. Start a new connection.",
    "credentials_expired" => "Kobo requires sign-in again. Connect the account again before refreshing its catalogue.",
    "catalogue_limit" => "The catalogue exceeded this preview's safety limit. Your previous catalogue has been kept.",
    "queue_unavailable" => "The catalogue refresh could not be queued. Try Refresh catalogue again."
  }.freeze

  belongs_to :user
  has_many :kobo_account_books, dependent: :destroy
  encrypts(*PRIVATE_ATTRIBUTES)

  validates :name, presence: true, length: { maximum: 80 }
  validates :status, inclusion: { in: STATUSES }
  validates :sync_status, inclusion: { in: SYNC_STATUSES }
  validates :device_id, :serial_number, presence: true
  validates :last_error, inclusion: { in: ERROR_MESSAGES.keys }, allow_nil: true
  normalizes :name, with: ->(value) { value.strip }

  def self.filter_attributes
    super + PRIVATE_ATTRIBUTES
  end

  def connected?
    status == "connected"
  end

  def usable?
    connected? && user && !user.deleted?
  end

  def pending?
    status == "pending" && activation_expires_at.present? && activation_expires_at.future?
  end

  def sync_active?
    sync_status != "idle" && sync_started_at.present? && sync_started_at > 5.minutes.ago
  end

  def error_message
    ERROR_MESSAGES[last_error]
  end

  def clear_activation
    { activation_poll_url: nil, activation_code: nil, activation_expires_at: nil, next_poll_at: nil }
  end
end
