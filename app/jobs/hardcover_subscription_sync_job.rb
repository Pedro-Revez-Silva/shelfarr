# frozen_string_literal: true

# Reads one Hardcover subscription's entries. Provider failures are recorded
# on the subscription with backoff instead of being retried immediately, so a
# rate limit or outage never turns into a burst of repeated requests.
class HardcoverSubscriptionSyncJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1,
    key: ->(subscription_id, *, **) { "hardcover-subscription-sync:#{subscription_id}" },
    duration: 15.minutes,
    on_conflict: :discard

  def perform(subscription_id, mode: "scheduled")
    subscription = HardcoverSubscription.find_by(id: subscription_id)
    return unless subscription && HardcoverIntegration.enabled?
    return if subscription.user.deleted?
    return if subscription.paused?

    snapshot = subscription.draft? || mode.to_s == "snapshot"
    subscription.update!(snapshot_state: "loading") if snapshot

    result = Hardcover::SubscriptionSync.call(subscription, mode: mode)
    HardcoverImportJob.perform_later if result.queued.positive?
  rescue HardcoverClient::RateLimitError => e
    fail_sync(subscription, snapshot, "Hardcover rate limit reached. Shelfarr will try again later.", retry_at: e.retry_at)
  rescue Hardcover::Credentials::Unavailable => e
    if subscription.requires_connection? && subscription.active?
      subscription.pause!(e.message)
    else
      fail_sync(subscription, snapshot, e.message)
    end
  rescue HardcoverClient::ScopeError => e
    fail_sync(subscription, snapshot, "#{e.message}. Reconnect Hardcover and approve the requested permissions.")
  rescue HardcoverClient::AuthenticationError
    message = "Hardcover rejected the credentials used for this sync."
    if subscription.requires_connection? && subscription.active?
      subscription.pause!("Reconnect your Hardcover account to resume.")
    else
      fail_sync(subscription, snapshot, message)
    end
  rescue HardcoverClient::Error, Hardcover::Oauth::Error => e
    fail_sync(subscription, snapshot, e.message)
  end

  private

  def fail_sync(subscription, snapshot, message, retry_at: nil)
    return unless subscription

    subscription.reload
    subscription.update!(snapshot_state: "failed") if snapshot || subscription.snapshot_loading?
    subscription.record_sync_failure!(message, retry_at: retry_at)
  end
end
