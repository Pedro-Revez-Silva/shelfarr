# frozen_string_literal: true

module Hardcover
  # Creates, replaces, and removes a user's Hardcover connection.
  module ConnectionManager
    RECONNECT_REASONS = [
      "Reconnect your Hardcover account to resume.",
      "Hardcover account disconnected."
    ].freeze

    module_function

    # Verifies the token by asking Hardcover who it belongs to, then stores
    # it. A replaced OAuth session is revoked so it does not linger on the
    # user's Authorized Apps page.
    def connect!(user:, auth_method:, access_token:, refresh_token: nil, expires_at: nil, scope: nil)
      account = Hardcover::API.me(credential: HardcoverClient.credential_for_token(access_token))
      previous = user.hardcover_connection
      previous_refresh_token = previous&.oauth? ? previous.refresh_token : nil

      connection = previous || user.build_hardcover_connection
      connection.assign_attributes(
        auth_method: auth_method,
        access_token: access_token,
        refresh_token: refresh_token,
        access_token_expires_at: expires_at,
        granted_scopes: scope,
        hardcover_user_id: account.id,
        hardcover_username: account.username,
        status: "active",
        last_error: nil,
        last_verified_at: Time.current,
        refreshed_at: nil
      )
      connection.save!

      Hardcover::Oauth.revoke(previous_refresh_token) if previous_refresh_token.present? && previous_refresh_token != refresh_token
      resume_paused_subscriptions(user)
      connection
    end

    def disconnect!(connection)
      user = connection.user
      token = connection.oauth? ? (connection.refresh_token.presence || connection.access_token) : nil
      connection.destroy!
      # Want to Read always needs the account; the user's own lists may be
      # private, and reading them without it would look like an empty list.
      own_lists = user.hardcover_subscriptions.where(kind: "list", owner_username: connection.hardcover_username)
      user.hardcover_subscriptions.requiring_connection.or(own_lists).where(status: %w[draft active]).find_each do |subscription|
        subscription.pause!("Hardcover account disconnected.")
      end
      Hardcover::Oauth.revoke(token) if token.present?
      true
    end

    def resume_paused_subscriptions(user)
      user.hardcover_subscriptions.where(status: "paused", pause_reason: RECONNECT_REASONS).find_each do |subscription|
        subscription.update!(
          status: subscription.baseline_established_at ? "active" : "draft",
          pause_reason: nil,
          consecutive_failures: 0,
          last_error: nil,
          next_sync_at: Time.current
        )
      end
    end
  end
end
