# frozen_string_literal: true

# Recurring entry point for Hardcover automation: queues subscriptions that
# are due, moves released upcoming books forward, re-queues failed imports
# whose backoff elapsed, and removes abandoned previews.
class HardcoverSyncSchedulerJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "hardcover-sync-scheduler", duration: 10.minutes, on_conflict: :discard

  MAX_SUBSCRIPTIONS_PER_RUN = 50

  def perform
    return unless HardcoverIntegration.enabled?

    promote_released_items
    requeue_failed_items
    enqueue_due_subscriptions
    HardcoverSubscription.stale_drafts.find_each(&:destroy)
    HardcoverImportJob.perform_later if HardcoverSubscriptionItem.claimable.exists?
  end

  private

  def active_items(scope)
    scope.joins(subscription: :user)
      .where(hardcover_subscriptions: { status: "active" })
      .where(users: { deleted_at: nil })
      .includes(:subscription)
  end

  # Books the user selected while unreleased, or any release on an automatic
  # subscription, are requested once they are out; others wait for the user.
  def promote_released_items
    active_items(HardcoverSubscriptionItem.released_upcoming).find_each do |item|
      subscription = item.subscription
      if item.wanted? || (subscription.automatic? && subscription.book_types.any?)
        item.update!(state: "queued", book_types: item.book_types.presence || subscription.book_types, next_attempt_at: nil)
      else
        item.update!(state: "pending")
      end
    end
  end

  def requeue_failed_items
    active_items(HardcoverSubscriptionItem.retry_due).find_each do |item|
      item.update!(state: "queued", claim_token: nil, claimed_at: nil)
    end
  end

  def enqueue_due_subscriptions
    HardcoverSubscription.due_for_sync.joins(:user).where(users: { deleted_at: nil })
      .order(Arel.sql("next_sync_at IS NOT NULL, next_sync_at ASC"))
      .limit(MAX_SUBSCRIPTIONS_PER_RUN)
      .pluck(:id)
      .each { |id| HardcoverSubscriptionSyncJob.perform_later(id) }
  end
end
