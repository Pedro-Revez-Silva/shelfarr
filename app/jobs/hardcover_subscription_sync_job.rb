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

  # A list or shelf with more changes than one run reads continues shortly.
  CONTINUE_DELAY = 1.minute

  def perform(subscription_id, mode: "scheduled")
    subscription = HardcoverSubscription.find_by(id: subscription_id)
    return unless subscription && HardcoverIntegration.enabled?
    return if subscription.user.deleted?
    return if subscription.paused?

    @generation = subscription.sync_generation
    snapshot = subscription.draft? || mode.to_s == "snapshot"
    subscription.update!(snapshot_state: "loading") if snapshot

    result = Hardcover::SubscriptionSync.call(subscription, mode: mode)
    HardcoverImportJob.perform_later if result.queued.positive?
    self.class.set(wait: CONTINUE_DELAY).perform_later(subscription.id) if result.continuing
  rescue Hardcover::SubscriptionSync::Stale => error
    # The account changed while reading; the new state has its own preview.
    RemoteResult::Failed.new(error)
  rescue HardcoverClient::RateLimitError => e
    fail_sync(subscription, snapshot, "Hardcover rate limit reached. Shelfarr will try again later.", retry_at: e.retry_at)
  rescue Hardcover::Credentials::Unavailable => e
    reason = e.is_a?(Hardcover::Credentials::AccountMismatch) ? HardcoverSubscription::PAUSE_OTHER_ACCOUNT : HardcoverSubscription::PAUSE_RECONNECT
    pause_or_fail(subscription, snapshot, reason, e.message)
  rescue HardcoverClient::ScopeError => e
    fail_sync(subscription, snapshot, "#{e.message}. Reconnect Hardcover and approve the requested permissions.")
  rescue HardcoverClient::AuthenticationError
    pause_or_fail(subscription, snapshot, HardcoverSubscription::PAUSE_RECONNECT, "Hardcover rejected the credentials used for this sync.")
  rescue HardcoverClient::Error, Hardcover::Oauth::Error => e
    fail_sync(subscription, snapshot, e.message)
  end

  private

  # Only acts on the subscription this run read: if the account changed
  # meanwhile, the fresh state must not inherit this run's failure.
  def current(subscription)
    return unless subscription

    fresh = HardcoverSubscription.find_by(id: subscription.id)
    fresh if fresh && fresh.sync_generation == @generation
  end

  def pause_or_fail(subscription, snapshot, pause_reason, message)
    fresh = current(subscription)
    return unless fresh

    if fresh.requires_connection? && fresh.active?
      fresh.pause!(pause_reason)
    else
      fail_sync(fresh, snapshot, message)
    end
  end

  def fail_sync(subscription, snapshot, message, retry_at: nil)
    fresh = current(subscription)
    return unless fresh

    fresh.update!(snapshot_state: "failed") if snapshot || fresh.snapshot_loading?
    fresh.record_sync_failure!(message, retry_at: retry_at)
  end
end
