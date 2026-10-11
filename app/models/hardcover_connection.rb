# frozen_string_literal: true

# A Shelfarr user's link to their own Hardcover account. Tokens are encrypted
# at rest, never rendered after they are saved, and only ever sent to
# Hardcover from the server.
#
# `lock_version` makes every write conditional on the row being unchanged
# since it was read, so a token refresh that finishes after the account was
# replaced or disconnected cannot overwrite or resurrect credentials.
class HardcoverConnection < ApplicationRecord
  AUTH_METHODS = %w[oauth personal_token].freeze
  STATUSES = %w[active reauthorization_required].freeze
  REFRESH_MARGIN = 5.minutes

  belongs_to :user

  encrypts :access_token
  encrypts :refresh_token

  validates :auth_method, inclusion: { in: AUTH_METHODS }
  validates :status, inclusion: { in: STATUSES }
  validates :access_token, presence: true
  validates :hardcover_user_id, presence: true, numericality: { only_integer: true, greater_than: 0 }

  def self.filter_attributes
    super + %i[access_token refresh_token]
  end

  def oauth?
    auth_method == "oauth"
  end

  def personal_token?
    auth_method == "personal_token"
  end

  def active?
    status == "active"
  end

  def usable?
    active? && user.present? && !user.deleted? && HardcoverIntegration.enabled?
  end

  def refreshable?
    oauth? && refresh_token.present?
  end

  def access_token_expiring?(margin: REFRESH_MARGIN)
    access_token_expires_at.present? && access_token_expires_at <= margin.from_now
  end

  # Hardcover rate limits each account across every app and token, so a
  # refreshed token must keep spending from the same budget.
  def credential
    HardcoverClient.credential_for_token(
      access_token,
      budget_key: HardcoverClient.account_budget_key(hardcover_user_id)
    )
  end

  # Ignored when the connection was replaced, refreshed, or removed since it
  # was read: the newer credentials decide.
  def mark_reauthorization_required!(message)
    transaction do
      update!(status: "reauthorization_required", last_error: message.to_s.truncate(250))
      user.hardcover_subscriptions.requiring_connection.where(status: "active").find_each do |subscription|
        subscription.pause!(HardcoverSubscription::PAUSE_RECONNECT)
      end
    end
    true
  rescue ActiveRecord::StaleObjectError
    false
  end

  def scope_list
    granted_scopes.to_s.split(/\s+/).compact_blank
  end
end
