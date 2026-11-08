# frozen_string_literal: true

module Kobo
  class ConnectionManager
    MAX_ACCOUNTS = 10
    POLL_INTERVAL = 5.seconds
    class LimitReached < StandardError; end

    def self.start(user:, name:)
      account = user.with_lock do
        if user.kobo_accounts.count >= MAX_ACCOUNTS || user.kobo_accounts.where(created_at: 1.minute.ago..).count >= 3
          raise LimitReached
        end
        user.kobo_accounts.create!(name: name.presence || "Kobo", device_id: SecureRandom.hex(32), serial_number: SecureRandom.hex(16))
      end
      activation = AccountClient.new(account).start_activation
      raise ActiveRecord::StaleObjectError unless User.active.exists?(account.user_id)

      account.update!(activation_poll_url: activation.poll_url, activation_code: activation.code,
        activation_expires_at: activation.expires_at, next_poll_at: POLL_INTERVAL.from_now)
      account
    rescue HttpClient::Error => error
      account.update!(status: "failed", last_error: error.code)
      account
    end

    def self.poll(account)
      return :failed unless User.active.exists?(account.user_id)
      return :approved if account.connected?
      return :failed unless account.status == "pending"

      unless account.pending?
        account.update!(account.clear_activation.merge(status: "expired", last_error: "activation_expired"))
        return :failed
      end
      return :pending if account.next_poll_at&.future?

      # Optimistic locking claims this polling interval before making a network
      # request. A late response cannot revive a disconnected connection.
      account.update!(next_poll_at: 1.minute.from_now)
      client = AccountClient.new(account)
      identity = client.poll_activation
      unless identity
        account.update!(next_poll_at: POLL_INTERVAL.from_now, last_error: nil)
        return :pending
      end

      credentials = client.authenticate(identity)
      raise ActiveRecord::StaleObjectError unless User.active.exists?(account.user_id)

      account.update!(account.clear_activation.merge(credentials).merge(status: "connected", last_error: nil))
      request_catalogue(account)
      :approved
    rescue HttpClient::Error => error
      status = %w[activation_expired credentials_expired].include?(error.code) ? "expired" : "pending"
      attributes = { status: status, last_error: error.code }
      attributes.merge!(account.clear_activation) if status == "expired"
      attributes[:next_poll_at] = 30.seconds.from_now if error.code == "provider_unavailable"
      persist_failure(account, attributes)
      :failed
    rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotFound
      :failed
    end

    def self.persist_failure(account, attributes)
      account.update!(attributes)
    rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotFound
      Rails.logger.info("[Kobo] Discarded an outdated sign-in failure")
    end

    def self.request_catalogue(account)
      return false unless account.usable?
      return false if account.sync_active?

      request_id = SecureRandom.uuid
      account.update!(sync_status: "queued", sync_request_id: request_id, sync_started_at: Time.current, last_error: nil)
      begin
        enqueued = KoboCatalogSyncJob.perform_later(account.id, request_id)
      rescue StandardError => error
        # Queue adapters can raise several unrelated error types. Never include
        # their message (or an inspected account) in logs or the response.
        Rails.logger.warn("[Kobo] Catalogue enqueue failed (#{error.class.name})")
        enqueued = false
      end
      unless enqueued
        account.update!(sync_status: "idle", last_error: "queue_unavailable")
      end
      enqueued.present?
    end
  end
end
