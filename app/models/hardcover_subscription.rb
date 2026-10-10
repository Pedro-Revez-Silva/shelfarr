# frozen_string_literal: true

# Something a user follows on Hardcover: their Want to Read shelf, a list, or
# an author. A subscription starts as a draft so the user can preview the
# current entries and choose what to request. Confirming it records those
# entries as the baseline; later syncs only act on what is new.
#
# A personal subscription (a Want to Read shelf, or a list that was not
# public) belongs to one Hardcover account and is only ever read with that
# account's own connection. Its baseline describes that account's entries, so
# connecting a different account starts a new preview instead of reusing it.
class HardcoverSubscription < ApplicationRecord
  KINDS = %w[want_to_read list author].freeze
  STATUSES = %w[draft active paused].freeze
  SNAPSHOT_STATES = %w[pending loading ready failed].freeze
  DRAFT_RETENTION = 7.days
  MAX_BACKOFF = 1.day
  PAUSE_RECONNECT = "Reconnect your Hardcover account to resume."
  PAUSE_DISCONNECTED = "Hardcover account disconnected."
  PAUSE_OTHER_ACCOUNT = "Connected to a different Hardcover account than the one this follows. Reconnect that account to resume."
  # Pauses that end by themselves once the right account is connected again.
  ACCOUNT_PAUSE_REASONS = [ PAUSE_RECONNECT, PAUSE_DISCONNECTED, PAUSE_OTHER_ACCOUNT ].freeze

  belongs_to :user
  has_many :items, class_name: "HardcoverSubscriptionItem", dependent: :delete_all, inverse_of: :subscription

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :snapshot_state, inclusion: { in: SNAPSHOT_STATES }
  validates :title, presence: true
  validates :target_key, presence: true, uniqueness: { scope: :user_id }
  validates :hardcover_target_id, numericality: { only_integer: true, greater_than: 0 }, unless: :want_to_read?
  validate :book_types_supported

  before_validation :assign_target_key
  after_update_commit :broadcast_progress, if: -> { saved_change_to_snapshot_state? || saved_change_to_last_synced_at? || saved_change_to_status? }

  scope :requiring_connection, -> { where(kind: "want_to_read").or(where(personal: true)) }
  scope :confirmed, -> { where(status: %w[active paused]) }
  scope :syncable, -> { where(status: "active") }
  scope :due_for_sync, ->(now = Time.current) { syncable.where("next_sync_at IS NULL OR next_sync_at <= ?", now) }
  scope :stale_drafts, ->(now = Time.current) { where(status: "draft").where("updated_at < ?", now - DRAFT_RETENTION) }

  def self.target_key_for(kind, target_id)
    kind.to_s == "want_to_read" ? "want_to_read" : "#{kind}:#{target_id.to_i}"
  end

  def want_to_read?
    kind == "want_to_read"
  end

  def list?
    kind == "list"
  end

  def author?
    kind == "author"
  end

  def draft?
    status == "draft"
  end

  def active?
    status == "active"
  end

  def paused?
    status == "paused"
  end

  def requires_connection?
    want_to_read? || personal?
  end

  # Whether a connection may read this subscription's entries with the
  # owner's privileges. Personal entries never fall back to another account.
  def owned_by_connection?(connection)
    connection.present? && hardcover_account_id.present? && connection.hardcover_user_id == hardcover_account_id
  end

  # Incremental reading stopped at a page limit and continues on the next run.
  def catching_up?
    sync_window_until.present?
  end

  def snapshot_ready?
    snapshot_state == "ready"
  end

  def snapshot_loading?
    snapshot_state.in?(%w[pending loading])
  end

  def book_types
    Array(super).map(&:to_s) & RequestOptionPolicy.book_types_for(ContentKinds::BOOK)
  end

  def kind_label
    case kind
    when "want_to_read" then "Want to Read"
    when "list" then "List"
    when "author" then "Author"
    end
  end

  def hardcover_url
    case kind
    when "author"
      slug.present? ? "https://hardcover.app/authors/#{slug}" : nil
    when "list"
      owner_username.present? && slug.present? ? "https://hardcover.app/@#{owner_username}/lists/#{slug}" : nil
    when "want_to_read"
      owner_username.present? ? "https://hardcover.app/@#{owner_username}/books/want-to-read" : nil
    end
  end

  def sync_interval
    hours = SettingsService.get(:hardcover_sync_interval_hours, default: 6).to_i
    hours.clamp(1, 168).hours
  end

  def schedule_next_sync!(from: Time.current)
    update!(next_sync_at: from + sync_interval)
  end

  def record_sync_failure!(message, retry_at: nil)
    failures = consecutive_failures + 1
    backoff = [ (2**[ failures - 1, 10 ].min) * 15.minutes, MAX_BACKOFF ].min
    next_at = [ retry_at, Time.current + backoff ].compact.max
    update!(consecutive_failures: failures, last_error: message.to_s.truncate(500), next_sync_at: next_at)
  end

  def pause!(reason)
    update!(status: "paused", pause_reason: reason.to_s.truncate(250))
  end

  def resume!
    update!(status: "active", pause_reason: nil, consecutive_failures: 0, last_error: nil, next_sync_at: Time.current)
  end

  # Starts a fresh preview of a different account's Want to Read shelf. The
  # previous account's entries and baseline are dropped so nothing from it
  # carries over; requests already created are kept. Bumping the generation
  # makes any sync still reading the old account discard its results.
  def restart_preview_for!(account_id:, username:)
    transaction do
      items.delete_all
      update!(
        status: "draft",
        hardcover_account_id: account_id,
        owner_username: username,
        personal: true,
        automatic: false,
        pause_reason: nil,
        snapshot_state: "pending",
        snapshot_completed_at: nil,
        entries_seen_count: 0,
        entries_truncated: false,
        baseline_established_at: nil,
        sync_cursor_at: nil,
        sync_window_since: nil,
        sync_window_until: nil,
        sync_window_before_id: nil,
        last_synced_at: nil,
        next_sync_at: nil,
        last_error: nil,
        consecutive_failures: 0,
        sync_generation: sync_generation + 1
      )
    end
  end

  def broadcast_progress
    broadcast_refresh_later_to self
  end

  private

  def assign_target_key
    self.target_key = self.class.target_key_for(kind, hardcover_target_id) if kind.present?
  end

  def book_types_supported
    raw = Array(read_attribute(:book_types)).map(&:to_s)
    allowed = RequestOptionPolicy.book_types_for(ContentKinds::BOOK)
    unsupported = raw - allowed
    errors.add(:book_types, "include unsupported formats: #{unsupported.join(', ')}") if unsupported.any?
    errors.add(:book_types, "must include at least one format") if !draft? && raw.empty?
  end
end
