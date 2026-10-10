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

    changed = promote_released_items + requeue_failed_items
    # Open subscription pages show item states; refresh each changed one once,
    # after its items are saved.
    HardcoverSubscription.where(id: changed.uniq).find_each(&:broadcast_progress)
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

  # Once an upcoming book is out:
  # * a book the user selected is requested;
  # * an automatic author subscription requests it, since following an
  #   author means watching their future releases;
  # * an automatic list or shelf only requests books added after its
  #   baseline. A future book that was already there and left unselected
  #   in the preview is never requested automatically.
  # Everything else waits for the user (baseline list books as not requested).
  # Both steps return the ids of the subscriptions whose items they changed.
  def promote_released_items
    active_items(HardcoverSubscriptionItem.released_upcoming).find_each.map do |item|
      subscription = item.subscription
      automatic = subscription.automatic? && subscription.book_types.any? && (subscription.author? || !item.baseline?)
      if item.wanted? || automatic
        item.update!(state: "queued", book_types: item.book_types.presence || subscription.book_types, next_attempt_at: nil)
      elsif item.baseline? && !subscription.author?
        item.update!(state: "known")
      else
        item.update!(state: "pending")
      end
      item.hardcover_subscription_id
    end
  end

  def requeue_failed_items
    active_items(HardcoverSubscriptionItem.retry_due).find_each.map do |item|
      item.update!(state: "queued", claim_token: nil, claimed_at: nil)
      item.hardcover_subscription_id
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
