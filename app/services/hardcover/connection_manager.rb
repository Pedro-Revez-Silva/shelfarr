# frozen_string_literal: true

module Hardcover
  # Creates, replaces, and removes a user's Hardcover connection.
  #
  # Replacing and removing go through the connection's optimistic lock, the
  # same guard a token refresh uses, so whichever finishes last can never
  # mix one account's tokens with another account's identity.
  module ConnectionManager
    MAX_ATTEMPTS = 3

    # The Shelfarr user was deleted while Hardcover was verifying the token.
    class UserUnavailable < HardcoverClient::Error; end
    class ConnectionChanged < HardcoverClient::Error; end

    ANY = :any
    DISCONNECTED_KEY = "hardcover:connection:disconnected-at:%d"
    DISCONNECT_MEMORY = 1.hour

    module_function

    # Verifies the token by asking Hardcover who it belongs to, then stores
    # it. A replaced OAuth session is revoked so it does not linger on the
    # user's Authorized Apps page.
    #
    # Personal subscriptions stay bound to the Hardcover account they were
    # previewed with. Reconnecting that account resumes them; connecting a
    # different one starts a fresh Want to Read preview and pauses private
    # lists owned by the other account. Nothing is requested either way.
    #
    # Verification happens outside any transaction and can take a while, so
    # the user is read again inside the write transaction. One deleted in the
    # meantime gets no connection, and a new OAuth grant is revoked.
    def connect!(user:, auth_method:, access_token:, refresh_token: nil, expires_at: nil, scope: nil, expected_version: ANY, started_at: nil)
      account = Hardcover::API.me(credential: HardcoverClient.credential_for_token(access_token))
      replaced_token = nil
      previews = []
      connection = nil
      attempts = 0

      begin
        attempts += 1
        HardcoverConnection.transaction do
          raise UserUnavailable, "This Shelfarr account is no longer active" unless active_user?(user)

          connection = HardcoverConnection.find_by(user_id: user.id) || HardcoverConnection.new(user: user)
          raise ConnectionChanged, "The Hardcover connection changed while signing in" unless expected_version == ANY || expected_version == (connection.persisted? ? connection.version : nil)
          raise ConnectionChanged, "The Hardcover account was disconnected while signing in" if expected_version != ANY && disconnected_since?(user, started_at)

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
      rescue UserUnavailable, ConnectionChanged
        Hardcover::Oauth.revoke(refresh_token.presence || access_token) if auth_method == "oauth"
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
    def disconnect!(connection, expected_version: ANY)
      user = connection.user
      token = nil
      replaced = false
      HardcoverConnection.transaction do
        current = HardcoverConnection.find_by(id: connection.id)
        replaced = expected_version != ANY && current&.version != expected_version
        next if replaced

        if current
          token = revocable_token(current)
          remember_disconnect(user)
          HardcoverConnection.where(id: current.id).delete_all
        end
        user.hardcover_subscriptions.requiring_connection.where(status: %w[draft active]).find_each do |subscription|
          subscription.pause!(HardcoverSubscription::PAUSE_DISCONNECTED)
        end
      end
      return false if replaced

      user.association(:hardcover_connection).reset
      Hardcover::Oauth.revoke(token) if token.present?
      true
    end

    # Read inside the write transaction. On SQLite that is an IMMEDIATE
    # transaction, like the one User#soft_delete! runs in, so a deletion
    # either commits first (and is seen here) or runs after this save and
    # removes the connection it finds.
    def active_user?(user)
      current = User.lock.find_by(id: user.id)
      current.present? && !current.deleted?
    end

    def remember_disconnect(user)
      Rails.cache.write(format(DISCONNECTED_KEY, user.id), Time.current.to_f, expires_in: DISCONNECT_MEMORY)
    rescue StandardError => error
      Rails.logger.warn("[Hardcover::ConnectionManager] Could not record a disconnect: #{error.class}")
      RemoteResult::Failed.new(error)
    end

    def disconnected_since?(user, started_at)
      disconnected_at = last_disconnect(user)
      started_at.is_a?(Numeric) && disconnected_at.is_a?(Numeric) && disconnected_at >= started_at
    end

    def last_disconnect(user)
      Rails.cache.read(format(DISCONNECTED_KEY, user.id))
    rescue StandardError => error
      Rails.logger.warn("[Hardcover::ConnectionManager] Could not read the last disconnect: #{error.class}")
      RemoteResult::Failed.new(error)
    end

    def revocable_token(connection)
      connection.oauth? ? (connection.refresh_token.presence || connection.access_token) : nil
    end

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
