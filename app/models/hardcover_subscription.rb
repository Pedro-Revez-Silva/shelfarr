# frozen_string_literal: true

# Something a user follows on Hardcover: their Want to Read shelf, a list, or
# an author. A subscription starts as a draft so the user can preview the
# current entries and choose what to request. Confirming it records those
# entries as the baseline; later syncs only act on what is new.
class HardcoverSubscription < ApplicationRecord
  KINDS = %w[want_to_read list author].freeze
  STATUSES = %w[draft active paused].freeze
  SNAPSHOT_STATES = %w[pending loading ready failed].freeze
  CONNECTION_KINDS = %w[want_to_read].freeze
  DRAFT_RETENTION = 7.days
  MAX_BACKOFF = 1.day

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

  scope :requiring_connection, -> { where(kind: CONNECTION_KINDS) }
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
    CONNECTION_KINDS.include?(kind)
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
