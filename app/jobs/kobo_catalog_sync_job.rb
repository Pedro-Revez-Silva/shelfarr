# frozen_string_literal: true

class KoboCatalogSyncJob < ApplicationJob
  queue_as :default
  # The queued -> syncing transition uses optimistic locking, rather than a
  # queue semaphore whose lease can expire while an execution is still ready.

  def perform(account_id, request_id)
    logger = ActiveRecord::Base.logger
    if logger&.respond_to?(:silence)
      logger.silence(Logger::INFO) { refresh_catalogue(account_id, request_id) }
    else
      refresh_catalogue(account_id, request_id)
    end
  end

  private

  def refresh_catalogue(account_id, request_id)
    account = KoboAccount.find_by(id: account_id)
    return unless account&.usable? && account.sync_request_id == request_id && account.sync_status == "queued"

    account.update!(sync_status: "syncing")
    entries = Kobo::CatalogueReader.new(account).call
    KoboAccount.transaction do
      raise ActiveRecord::StaleObjectError unless User.active.exists?(account.user_id)

      # This write checks lock_version before any catalogue rows change. A
      # disconnect or newer refresh invalidates the entire older result.
      account.update!(sync_status: "idle", last_synced_at: Time.current, last_error: nil)
      entries.each do |attributes|
        book = account.kobo_account_books.find_or_initialize_by(entitlement_id: attributes.fetch(:entitlement_id))
        next if book.new_record? && !attributes.key?(:title)

        book.update!(attributes)
      end
    end
  rescue Kobo::HttpClient::Error => error
    record_failure(account, error)
  rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotFound
    Rails.logger.info("[Kobo] Discarded an outdated catalogue or sign-in result")
  end

  def record_failure(account, error)
    account.update!(sync_status: "idle", last_error: error.code,
      status: error.code == "credentials_expired" ? "reauthorization_required" : account.status)
  rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotFound
    Rails.logger.info("[Kobo] Discarded an outdated catalogue failure")
  end
end
