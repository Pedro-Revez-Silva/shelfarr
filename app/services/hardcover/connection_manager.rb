# frozen_string_literal: true

module Hardcover
  # Creates, replaces, and removes a user's Hardcover connection.
  #
  # Replacing and removing go through the connection's optimistic lock, the
  # same guard a token refresh uses, so whichever finishes last can never
  # mix one account's tokens with another account's identity.
  module ConnectionManager
    MAX_ATTEMPTS = 3

    module_function

    # Verifies the token by asking Hardcover who it belongs to, then stores
    # it. A replaced OAuth session is revoked so it does not linger on the
    # user's Authorized Apps page.
    #
    # Personal subscriptions stay bound to the Hardcover account they were
    # previewed with. Reconnecting that account resumes them; connecting a
    # different one starts a fresh Want to Read preview and pauses private
    # lists owned by the other account. Nothing is requested either way.
    def connect!(user:, auth_method:, access_token:, refresh_token: nil, expires_at: nil, scope: nil)
      account = Hardcover::API.me(credential: HardcoverClient.credential_for_token(access_token))
      replaced_token = nil
      previews = []
      connection = nil
      attempts = 0

      begin
        attempts += 1
        HardcoverConnection.transaction do
          connection = HardcoverConnection.find_by(user_id: user.id) || HardcoverConnection.new(user: user)
          replaced_token = connection.persisted? ? revocable_token(connection) : nil
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
          previews = rebind_personal_subscriptions(user, account)
        end
      rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotUnique
        retry if attempts < MAX_ATTEMPTS
        raise
      end

      user.association(:hardcover_connection).target = connection
      Hardcover::Oauth.revoke(replaced_token) if replaced_token.present? && replaced_token != refresh_token
      previews.each { |id| HardcoverSubscriptionSyncJob.perform_later(id, mode: "snapshot") }
      connection
    end

    # Deletes the stored tokens unconditionally. A refresh still in flight
    # then fails its versioned write and revokes what it received, so it
    # cannot bring the connection back.
    def disconnect!(connection)
      user = connection.user
      token = nil
      HardcoverConnection.transaction do
        current = HardcoverConnection.find_by(id: connection.id)
        if current
          token = revocable_token(current)
          HardcoverConnection.where(id: current.id).delete_all
        end
        user.hardcover_subscriptions.requiring_connection.where(status: %w[draft active]).find_each do |subscription|
          subscription.pause!(HardcoverSubscription::PAUSE_DISCONNECTED)
        end
      end
      user.association(:hardcover_connection).reset
      Hardcover::Oauth.revoke(token) if token.present?
      true
    end

    def revocable_token(connection)
      connection.oauth? ? (connection.refresh_token.presence || connection.access_token) : nil
    end

    # Returns the ids of subscriptions that need a fresh preview.
    def rebind_personal_subscriptions(user, account)
      previews = []
      user.hardcover_subscriptions.requiring_connection.find_each do |subscription|
        if subscription.hardcover_account_id == account.id
          resume_for_account(subscription, account)
        elsif subscription.want_to_read?
          subscription.restart_preview_for!(account_id: account.id, username: account.username)
          previews << subscription.id
        elsif !subscription.paused? || subscription.pause_reason.in?(HardcoverSubscription::ACCOUNT_PAUSE_REASONS)
          subscription.pause!(HardcoverSubscription::PAUSE_OTHER_ACCOUNT)
        end
      end
      previews
    end

    def resume_for_account(subscription, account)
      subscription.owner_username = account.username if subscription.want_to_read? && account.username.present?
      if subscription.paused? && subscription.pause_reason.in?(HardcoverSubscription::ACCOUNT_PAUSE_REASONS)
        subscription.assign_attributes(
          status: subscription.baseline_established_at ? "active" : "draft",
          pause_reason: nil,
          consecutive_failures: 0,
          last_error: nil,
          next_sync_at: Time.current
        )
      end
      subscription.save! if subscription.changed?
    end
  end
end
