# frozen_string_literal: true

require "digest"

class OwnedMediaImport < ApplicationRecord
  STATUSES = %w[pending queued starting downloading processing completed failed cancelled].freeze
  ACTIVE_STATUSES = %w[queued starting downloading processing].freeze
  TERMINAL_STATUSES = %w[completed failed cancelled].freeze
  RECOVERY_GRACE_PERIOD = 2.minutes
  POLL_TOKEN_BYTES = 16
  POLL_TOKEN_DOMAIN = "shelfarr-owned-media-poll-v1:"

  belongs_to :owned_library_item
  belongs_to :request, optional: true
  belongs_to :upload, optional: true
  belongs_to :created_book, class_name: "Book", optional: true
  belongs_to :requested_by, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :external_job_id, uniqueness: true, allow_nil: true
  validates :poll_token, length: { maximum: 64 }, allow_nil: true
  validate :staged_identity_is_complete
  validate :only_one_active_import, on: :create

  after_create_commit :broadcast_owned_library_refresh_later
  after_update_commit :broadcast_owned_library_refresh_later_if_needed
  after_update_commit :dispatch_next_automatic_backup_if_terminal
  before_destroy :prevent_unsafe_destruction, prepend: true

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :recovery_reserved, -> {
    where.not(status: "completed").where.not(destination_path: [ nil, "" ])
  }
  scope :blocking, -> {
    where(status: ACTIVE_STATUSES).or(recovery_reserved)
  }
  scope :cancellation_blocking, -> {
    unfinished = where(status: [ "pending", *ACTIVE_STATUSES ])
    recovery_state = where.not(status: "completed").where(
      "COALESCE(destination_path, '') != '' OR " \
        "COALESCE(library_path, '') != '' OR " \
        "staged_device IS NOT NULL OR staged_inode IS NOT NULL"
    )
    unfinished.or(recovery_state)
  }
  scope :automatic, -> { where(automatic: true) }
  scope :pending, -> { where(status: "pending") }
  scope :terminal, -> { where(status: TERMINAL_STATUSES) }
  scope :recent, -> { order(created_at: :desc) }

  def self.latest_by_owned_library_item_id(item_ids)
    ids = Array(item_ids).filter_map { |id| Integer(id, exception: false) }.uniq
    return {} if ids.empty?

    columns = column_names.map do |name|
      "ranked_imports.#{connection.quote_column_name(name)}"
    end.join(", ")
    ranked_imports = find_by_sql(<<~SQL.squish)
      SELECT #{columns}
      FROM (
        SELECT
          owned_media_imports.*,
          ROW_NUMBER() OVER (
            PARTITION BY owned_library_item_id
            ORDER BY created_at DESC, id DESC
          ) AS shelfarr_latest_rank
        FROM owned_media_imports
        WHERE owned_library_item_id IN (#{ids.join(", ")})
      ) AS ranked_imports
      WHERE ranked_imports.shelfarr_latest_rank = 1
    SQL
    ranked_imports.index_by(&:owned_library_item_id)
  end

  def active?
    status.in?(ACTIVE_STATUSES)
  end

  def pending?
    status == "pending"
  end

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  def recoverable?
    active? && updated_at <= RECOVERY_GRACE_PERIOD.ago
  end

  def recovery_reserved?
    !completed? && destination_path.present?
  end

  def recovery_state?
    destination_path.present? || library_path.present? ||
      staged_device.present? || staged_inode.present?
  end

  def destruction_blocked?
    !completed? && (pending? || active? || recovery_state?)
  end

  def self.generate_poll_token
    SecureRandom.hex(POLL_TOKEN_BYTES)
  end

  def self.next_poll_token(current_token)
    Digest::SHA256.hexdigest("#{POLL_TOKEN_DOMAIN}#{current_token}")
  end

  # Claims a durable polling chain. Jobs from releases predating poll_token may
  # arrive either without a token or with updated_at as their token; the first
  # valid legacy delivery upgrades the row in place. Once upgraded, un-tokened
  # and timestamp-tokened redeliveries are rejected.
  def claim_poll_token(candidate = nil)
    with_lock do
      reload
      next unless active?

      if poll_token.present?
        next poll_token if poll_token_matches?(candidate)

        successor = self.class.next_poll_token(poll_token)
        if secure_token_match?(successor, candidate)
          update!(poll_token: successor)
          next successor
        end

        next
      end

      if candidate.present? && candidate != legacy_poll_token
        next
      end

      token = self.class.generate_poll_token
      update!(poll_token: token)
      token
    end
  end

  def poll_token_matches?(candidate)
    poll_token.present? && secure_token_match?(poll_token, candidate)
  end

  STATUSES.each do |value|
    define_method("#{value}?") { status == value }
  end

  def mark_failed!(message, poll_token: nil)
    with_lock do
      reload
      next false unless active?
      next false if poll_token.present? && !poll_token_matches?(poll_token)

      update!(
        status: "failed",
        error_message: message.to_s.truncate(2_000),
        completed_at: Time.current
      )
      true
    end
  end

  private

  def prevent_unsafe_destruction
    return unless destruction_blocked?

    errors.add(
      :base,
      "This Audible import is queued, processing, or owns recovery state and cannot be deleted safely"
    )
    throw :abort
  end

  def staged_identity_is_complete
    return if staged_device.present? == staged_inode.present?

    errors.add(:base, "Staged file identity must include both device and inode")
  end

  def secure_token_match?(expected, candidate)
    candidate = candidate.to_s
    candidate.bytesize == expected.bytesize &&
      ActiveSupport::SecurityUtils.secure_compare(expected, candidate)
  end

  def legacy_poll_token
    updated_at&.utc&.iso8601(6)
  end

  def broadcast_owned_library_refresh_later_if_needed
    return if (previous_changes.keys & %w[status error_message upload_id completed_at dispatched_at]).empty?

    broadcast_owned_library_refresh_later
  end

  def broadcast_owned_library_refresh_later
    owned_library_item.owned_library_connection.broadcast_owned_library_refresh_later
  end

  def dispatch_next_automatic_backup_if_terminal
    status_change = previous_changes["status"]
    return unless automatic? && dispatched_at.present? && status_change.present?
    return if status_change.first.in?(TERMINAL_STATUSES)
    return unless status_change.last.in?(TERMINAL_STATUSES)

    connection = owned_library_item.owned_library_connection
    OwnedLibraryBacklogBackup.dispatch_next(connection: connection)
  rescue StandardError => error
    # The recurring automation job remains the durable watchdog. Never roll a
    # completed/failed import back because its immediate successor handoff had
    # a transient problem.
    Rails.logger.error(
      "[OwnedMediaImport] Could not dispatch after terminal import ##{id}: #{error.class}"
    )
  end

  def only_one_active_import
    return unless status.in?(ACTIVE_STATUSES)
    return unless owned_library_item&.owned_media_imports&.blocking&.where&.not(id: id)&.exists?

    errors.add(:base, "A backup is already active for this library item")
  end
end
