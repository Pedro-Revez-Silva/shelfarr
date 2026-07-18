# frozen_string_literal: true

class RequestQueueJob < ApplicationJob
  RECONCILIATION_BATCH_SIZE = 100
  MAX_PROCESS_BATCH_SIZE = 100
  CONCURRENCY_LEASE = 10.minutes

  queue_as :default
  limits_concurrency to: 1,
    key: "request-queue",
    duration: CONCURRENCY_LEASE,
    on_conflict: :discard

  def perform
    requeue_retry_due_requests
    requeue_requests_without_visible_store_offers
    process_pending_requests
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

  # Enqueue the search job for a pending request
  def enqueue_search(request)
    SearchJob.perform_later(request.id)
    Rails.logger.info "[RequestQueueJob] Enqueued SearchJob for request ##{request.id}"
  end
end
