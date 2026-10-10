# frozen_string_literal: true

# How many automatic Hardcover requests a user has used in the current check
# window. The administrator's limit applies to each window, which is as long
# as the interval between checks, across all of the user's subscriptions and
# every import batch, restart, and retry within it. Each requested format
# counts once; formats already in Shelfarr and books the user selected
# themselves do not count.
class HardcoverRequestBudget < ApplicationRecord
  belongs_to :user

  validates :window_started_at, presence: true
  validates :used, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Users with no automatic requests left in their current window.
  scope :exhausted, ->(now = Time.current) {
    where("window_started_at > ?", now - HardcoverIntegration.sync_interval)
      .where("used >= ?", HardcoverIntegration.max_automatic_requests_per_run)
  }

  # The user's budget, locked for the rest of the caller's transaction. A
  # window that has ended starts over from now.
  def self.current_for!(user, now: Time.current)
    budget = lock.find_by(user_id: user.id) || create!(user: user, window_started_at: now)
    budget.update!(window_started_at: now, used: 0) if budget.window_ends_at <= now
    budget
  end

  def window_ends_at
    window_started_at + HardcoverIntegration.sync_interval
  end

  def remaining
    [ HardcoverIntegration.max_automatic_requests_per_run - used, 0 ].max
  end

  def consume!(count)
    update!(used: used + count) if count.positive?
  end
end
