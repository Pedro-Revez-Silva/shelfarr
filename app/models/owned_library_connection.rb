# frozen_string_literal: true

require "uri"
require "base64"

class OwnedLibraryConnection < ApplicationRecord
  PROVIDERS = %w[libation].freeze
  SYNC_STATUSES = %w[idle queued syncing failed].freeze
  SCHEDULED_SYNC_INTERVAL_MINUTES = [ 60, 360, 720, 1_440, 4_320, 10_080 ].freeze
  DEFAULT_SCHEDULED_SYNC_INTERVAL_MINUTES = 1_440
  LIVE_UPDATE_ATTRIBUTES = %w[
    automatic_backup_enabled
    automatic_backup_enabled_at
    automatic_backup_user_id
    backlog_backup_decided_at
    companion_version
    enabled
    last_sync_error
    last_synced_at
    next_scheduled_sync_at
    provider_version
    scheduled_sync_enabled
    scheduled_sync_interval_minutes
    sync_job_id
    sync_started_at
    sync_status
  ].freeze
  DEFAULT_LIBATION_URL = "http://shelfarr-libation:8080"
  AUTH_START_PREFIX = "shelfarr-starting:"
  AUTH_START_TIMEOUT = 3.minutes
  SYNC_JOB_STATE_PREFIX = "shelfarr-sync:v1:"

  encrypts :bridge_token, :auth_session_id, :auth_login_url

  has_many :owned_library_items, dependent: :destroy
  has_many :owned_media_imports, through: :owned_library_items
  belongs_to :automatic_backup_user, class_name: "User", optional: true

  before_validation :normalize_url
  before_validation :apply_defaults
  before_validation :maintain_scheduled_sync_deadline
  before_validation :maintain_automatic_backup_baseline
  before_validation :clear_endpoint_bound_state_for_changed_url, on: :update
  before_destroy :prevent_destroy_during_owned_library_operation, prepend: true
  after_update_commit :broadcast_owned_library_refresh_later_if_needed

  validates :provider, presence: true, inclusion: { in: PROVIDERS }, uniqueness: true
  validates :name, presence: true
  validates :url, presence: true
  validates :timeout_seconds,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 120 }
  validates :sync_status, inclusion: { in: SYNC_STATUSES }
  validates :scheduled_sync_interval_minutes,
    inclusion: { in: SCHEDULED_SYNC_INTERVAL_MINUTES }
  validate :url_is_http
  validate :url_transport_is_safe
  validate :url_private_network_access
  validate :bridge_token_present_for_enabled_custom_url
  validate :automatic_backup_user_present_when_configuration_changes

  scope :enabled, -> { where(enabled: true) }
  scope :for_provider, ->(provider) { where(provider: provider.to_s) }
  scope :scheduled_sync_due, ->(at = Time.current) do
    enabled
      .where(scheduled_sync_enabled: true)
      .where("next_scheduled_sync_at IS NULL OR next_scheduled_sync_at <= ?", at)
  end

  def self.default_libation_url
    value = ENV.fetch("SHELFARR_LIBATION_URL", DEFAULT_LIBATION_URL).presence || DEFAULT_LIBATION_URL
    value.to_s.strip.delete_suffix("/")
  end

  def client
    case provider
    when "libation"
      LibationCompanionClient.new(self)
    else
      raise ArgumentError, "Unsupported owned-library provider: #{provider}"
    end
  end

  def queued?
    sync_status == "queued"
  end

  def syncing?
    sync_status == "syncing"
  end

  def sync_active?
    queued? || syncing?
  end

  def scheduled_sync_due?(at: Time.current)
    enabled? && scheduled_sync_enabled? &&
      (next_scheduled_sync_at.blank? || next_scheduled_sync_at <= at)
  end

  def next_scheduled_sync_time(from: Time.current)
    from + scheduled_sync_interval_minutes.to_i.minutes
  end

  def automatic_backup_ready?
    automatic_backup_enabled? && automatic_backup_enabled_at.present? &&
      automatic_backup_user_eligible?
  end

  def automatic_backup_baseline_ready?
    automatic_backup_ready? && last_synced_at.present? &&
      last_synced_at >= automatic_backup_enabled_at
  end

  def backlog_backup_decided?
    backlog_backup_decided_at.present?
  end

  # Keep the companion job ID and Shelfarr's polling-chain token in the
  # existing sync_job_id column. Raw IDs written by older Shelfarr releases
  # remain readable, so this does not require a data migration.
  def sync_job_id
    state = decoded_sync_job_state
    state ? state.fetch(:job_id).presence : self[:sync_job_id]
  end

  def sync_poll_token
    decoded_sync_job_state&.fetch(:poll_token)
  end

  def sync_job_state_value(job_id:, poll_token:)
    encoded_job_id = Base64.urlsafe_encode64(job_id.to_s, padding: false)
    "#{SYNC_JOB_STATE_PREFIX}#{poll_token}:#{encoded_job_id}"
  end

  def failed?
    sync_status == "failed"
  end

  def auth_pending?
    auth_session_id.present? && auth_login_url.present? &&
      (auth_expires_at.blank? || auth_expires_at.future?)
  end

  def auth_starting?
    auth_session_id.to_s.start_with?(AUTH_START_PREFIX) &&
      auth_login_url.blank? && auth_expires_at&.future?
  end

  def auth_active?
    auth_starting? || auth_pending?
  end

  def stale_auth_state?
    (auth_session_id.present? || auth_login_url.present? || auth_expires_at.present?) && !auth_active?
  end

  def auth_state_snapshot
    {
      session_id: auth_session_id,
      login_url: auth_login_url,
      expires_at: auth_expires_at
    }
  end

  def clear_auth_state!
    update!(auth_session_id: nil, auth_login_url: nil, auth_expires_at: nil)
  end

  def clear_auth_state_if_current!(expected_state)
    with_lock do
      reload
      next false unless auth_state_snapshot == expected_state

      clear_auth_state!
      true
    end
  end

  def broadcast_owned_library_refresh_later
    broadcast_refresh_later_to self
  end

  private

  def prevent_destroy_during_owned_library_operation
    blocked = auth_active? || sync_active? || owned_media_imports.cancellation_blocking.exists?
    return unless blocked

    errors.add(
      :base,
      "This Audible connection has an active sign-in, sync, or recoverable backup and cannot be deleted safely"
    )
    throw :abort
  end

  def decoded_sync_job_state
    raw_value = self[:sync_job_id].to_s
    return unless raw_value.start_with?(SYNC_JOB_STATE_PREFIX)

    poll_token, encoded_job_id = raw_value.delete_prefix(SYNC_JOB_STATE_PREFIX).split(":", 2)
    return if poll_token.blank? || encoded_job_id.nil?

    {
      job_id: Base64.urlsafe_decode64(encoded_job_id),
      poll_token: poll_token
    }
  rescue ArgumentError
    nil
  end

  def normalize_url
    self.url = url.to_s.strip.delete_suffix("/") if url.present?
  end

  def apply_defaults
    self.provider = "libation" if provider.blank?
    self.name = "Audible Backup" if name.blank? && provider == "libation"
    self.url = self.class.default_libation_url if url.blank? && provider == "libation"
  end

  def maintain_scheduled_sync_deadline
    if will_save_change_to_scheduled_sync_enabled?
      self.next_scheduled_sync_at = scheduled_sync_enabled? ? next_scheduled_sync_time : nil
    elsif scheduled_sync_enabled? && will_save_change_to_scheduled_sync_interval_minutes?
      self.next_scheduled_sync_at = next_scheduled_sync_time
    end
  end

  def maintain_automatic_backup_baseline
    return unless will_save_change_to_automatic_backup_enabled?

    self.automatic_backup_enabled_at = automatic_backup_enabled? ? Time.current : nil
  end

  def clear_endpoint_bound_state_for_changed_url
    return unless will_save_change_to_url?

    self.bridge_token = nil unless will_save_change_to_bridge_token?
    self.auth_session_id = nil
    self.auth_login_url = nil
    self.auth_expires_at = nil
    self.companion_version = nil
    self.provider_version = nil
  end

  def broadcast_owned_library_refresh_later_if_needed
    return if (previous_changes.keys & LIVE_UPDATE_ATTRIBUTES).empty?

    broadcast_owned_library_refresh_later
  end

  def bridge_token_present_for_enabled_custom_url
    return unless enabled?
    return if url == self.class.default_libation_url
    return if bridge_token.present?

    errors.add(:bridge_token, "is required for an enabled custom companion URL")
  end

  def automatic_backup_user_present_when_configuration_changes
    return unless automatic_backup_enabled?
    return unless will_save_change_to_automatic_backup_enabled? ||
      will_save_change_to_automatic_backup_user_id?
    return if automatic_backup_user_eligible?

    errors.add(:automatic_backup_user, "must be an active administrator")
  end

  def automatic_backup_user_eligible?
    automatic_backup_user.present? && automatic_backup_user.admin? &&
      automatic_backup_user.deleted_at.blank?
  end

  def url_is_http
    uri = URI.parse(url.to_s)
    return if %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.blank?

    errors.add(:url, "must be a valid http or https URL without embedded credentials")
  rescue URI::InvalidURIError
    errors.add(:url, "must be a valid http or https URL without embedded credentials")
  end

  def url_private_network_access
    return if allow_private_network?
    return if url.blank? || errors.include?(:url)

    host = URI.parse(url).host
    return unless OutboundUrlGuard.obviously_private_host?(host)

    errors.add(:url, "points to a private network address. Enable private network access for a local companion.")
  rescue URI::InvalidURIError
    nil
  end

  def url_transport_is_safe
    uri = URI.parse(url.to_s)
    return unless uri.scheme == "http"
    return if allow_private_network?

    errors.add(:url, "must use HTTPS unless private network access is enabled")
  rescue URI::InvalidURIError
    nil
  end
end
