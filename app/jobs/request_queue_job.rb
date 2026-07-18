# frozen_string_literal: true

class RequestQueueJob < ApplicationJob
  RECONCILIATION_BATCH_SIZE = 100
  MAX_PROCESS_BATCH_SIZE = 100
  CONCURRENCY_LEASE = 10.minutes
  STALE_SEARCH_LEASE = 30.minutes

  queue_as :default
  limits_concurrency to: 1,
    key: "request-queue",
    duration: CONCURRENCY_LEASE,
    on_conflict: :discard

  def perform
    requeue_retry_due_requests
    requeue_requests_without_visible_store_offers
    process_pending_requests
    recover_stale_searches
  end

  private

  # Re-queue not_found requests that are due for retry
  def requeue_retry_due_requests
    Request.retry_due.order(:next_retry_at, :id).limit(RECONCILIATION_BATCH_SIZE).each do |request|
      Rails.logger.info "[RequestQueueJob] Re-queuing request ##{request.id} for retry (attempt #{request.retry_count + 1})"
      request.requeue!
    end
  end

  # Pick up pending requests in FIFO order, limited by batch size
  def process_pending_requests
    batch_size = processing_batch_size
    requests = Request.processable.limit(batch_size)

    Rails.logger.info "[RequestQueueJob] Processing #{requests.count} pending requests (batch_size: #{batch_size})"

    requests.each do |request|
      enqueue_search(request)
    end
  end

  def processing_batch_size
    SettingsService.get(:queue_batch_size).to_i.clamp(0, MAX_PROCESS_BATCH_SIZE)
  end

  # Environment-managed provider settings can change without passing through
  # SettingsService#set. Reconcile the state periodically so an offer-only
  # request never remains awaiting purchase after every visible offer vanished.
  def requeue_requests_without_visible_store_offers
    StoreProviderRegistry.awaiting_requests_without_visible_offers
      .includes(:book)
      .order(:id)
      .limit(RECONCILIATION_BATCH_SIZE)
      .each do |request|
        request.with_lock do
          next unless request.awaiting_purchase?
          next if StoreProviderRegistry.visible_offers_for(request).exists?

          request.store_offers.delete_all
          RequestEvent.clear_latest!(
            request: request,
            event_type: "store_offers_found",
            source: "store_provider"
          )
          request.update!(
            status: :pending,
            attention_needed: false,
            issue_description: nil,
            next_retry_at: nil
          )
        end
      rescue ActiveRecord::RecordNotFound
        next
      end
  end

  # A hard-killed SearchJob cannot clear its durable claim. Recover claims whose
  # start timestamp has exceeded the bounded lease, but only after ordinary
  # pending dispatch so the replacement is not enqueued twice in this run.
  def recover_stale_searches
    stale_before = STALE_SEARCH_LEASE.ago
    Request.searching
      .where.not(search_claimed_at: nil)
      .where("search_claimed_at <= ?", stale_before)
      .order(:search_claimed_at, :id)
      .limit(RECONCILIATION_BATCH_SIZE)
      .each do |request|
        next unless request.recover_stale_search!(stale_before: stale_before)

        enqueue_search(request)
      rescue ActiveRecord::RecordNotFound
        next
      rescue StandardError => e
        # The request is already pending with a rotated generation when an
        # enqueue fails. The ordinary pending pass repairs it on the next run;
        # keep reconciling the remainder of this bounded batch now.
        Rails.logger.error(
          "[RequestQueueJob] Failed to recover stale search for request ##{request.id}: #{e.class}"
        )
      end
  end

  # Enqueue the search job for a pending request
  def enqueue_search(request)
    SearchJob.perform_later(request.id)
    Rails.logger.info "[RequestQueueJob] Enqueued SearchJob for request ##{request.id}"
  end
end
