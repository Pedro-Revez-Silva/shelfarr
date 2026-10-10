# frozen_string_literal: true

# One Hardcover book tracked by a subscription. The state records what
# Shelfarr has decided about it so syncs, retries, and restarts never request
# the same book twice or silently drop it.
class HardcoverSubscriptionItem < ApplicationRecord
  # known:     present when the baseline was taken; not requested automatically
  # pending:   new since the baseline, waiting for the user to decide
  # queued:    waiting for the import job to create requests
  # requested: requests exist (created here or already present in Shelfarr)
  # upcoming:  not released yet; re-evaluated when it is released
  # failed:    the import failed; retried with backoff, then needs a manual retry
  # ignored:   the user dismissed it
  STATES = %w[known pending queued requested upcoming failed ignored].freeze
  REQUESTABLE_STATES = %w[known pending failed ignored].freeze
  MAX_AUTOMATIC_ATTEMPTS = 5
  CLAIM_TIMEOUT = 15.minutes

  belongs_to :subscription, class_name: "HardcoverSubscription", foreign_key: :hardcover_subscription_id, inverse_of: :items

  validates :state, inclusion: { in: STATES }
  validates :title, presence: true
  validates :hardcover_book_id, numericality: { only_integer: true, greater_than: 0 },
    uniqueness: { scope: :hardcover_subscription_id }

  STATES.each do |value|
    scope value, -> { where(state: value) }
    define_method(:"#{value}?") { state == value }
  end

  scope :claimable, ->(now = Time.current) {
    where(state: "queued")
      .where("claimed_at IS NULL OR claimed_at < ?", now - CLAIM_TIMEOUT)
      .where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
  }
  scope :retry_due, ->(now = Time.current) {
    failed.where("attempts < ?", MAX_AUTOMATIC_ATTEMPTS).where("next_attempt_at IS NOT NULL AND next_attempt_at <= ?", now)
  }
  scope :released_upcoming, ->(today = Date.current) { upcoming.where("release_date IS NOT NULL AND release_date <= ?", today) }

  def work_id
    "hardcover:#{hardcover_book_id}"
  end

  def requestable?
    REQUESTABLE_STATES.include?(state) && !unreleased?
  end

  def unreleased?(today = Date.current)
    release_date.present? && release_date > today
  end

  def book_types
    Array(super).map(&:to_s)
  end

  def request_ids
    Array(super).map(&:to_i)
  end

  def hardcover_url
    MetadataSources.hardcover_book_url(hardcover_book_id)
  end

  def metadata_attrs
    {
      title: title,
      author: author,
      cover_url: cover_url,
      first_publish_year: release_year,
      description: description,
      release_date: release_date,
      series: series_name,
      series_position: series_position,
      content_kind: ContentKinds::BOOK
    }.compact
  end

  def state_label
    case state
    when "known" then "Not requested"
    when "pending" then "New"
    when "queued" then "Queued"
    when "requested" then "Requested"
    when "upcoming" then wanted? ? "Upcoming · will request" : "Upcoming"
    when "failed" then "Failed"
    when "ignored" then "Dismissed"
    end
  end

  # Selecting the book makes the import job request it with these formats.
  def queue_for_import!(book_types)
    update!(
      state: "queued",
      book_types: book_types,
      wanted: true,
      attempts: 0,
      claim_token: nil,
      claimed_at: nil,
      next_attempt_at: nil,
      last_error: nil
    )
  end
end
