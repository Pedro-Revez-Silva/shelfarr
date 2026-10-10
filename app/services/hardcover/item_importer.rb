# frozen_string_literal: true

module Hardcover
  # Turns queued subscription items into ordinary Shelfarr requests through
  # RequestCreationService.
  #
  # Items are claimed with a token before any work starts, so concurrent or
  # restarted jobs never import one item twice. Formats that are already in
  # the library or already requested count as done, which also makes a retry
  # after a crash idempotent. Failures are recorded on the item for automatic
  # retry with backoff instead of being dropped.
  class ItemImporter
    BATCH_SIZE = 25
    AUTOMATIC_DEFER = 15.minutes

    Result = Data.define(:processed, :requested, :failed, :deferred, :remaining)

    def self.call(...)
      new(...).call
    end

    def initialize(batch_size: BATCH_SIZE, now: Time.current)
      @batch_size = batch_size
      @now = now
      @automatic_counts = Hash.new(0)
    end

    def call
      return Result.new(processed: 0, requested: 0, failed: 0, deferred: 0, remaining: 0) unless HardcoverIntegration.enabled?

      requested = failed = deferred = 0
      items = claim_batch
      items.each do |item|
        case process(item)
        when :requested then requested += 1
        when :failed then failed += 1
        when :deferred then deferred += 1
        end
      end

      items.map(&:subscription).uniq.each(&:broadcast_progress)
      Result.new(processed: items.size, requested: requested, failed: failed, deferred: deferred, remaining: eligible_scope.count)
    end

    private

    attr_reader :batch_size, :now

    def eligible_scope
      HardcoverSubscriptionItem.claimable(now)
        .joins(subscription: :user)
        .where(hardcover_subscriptions: { status: "active" })
        .where(users: { deleted_at: nil })
    end

    def claim_batch
      token = SecureRandom.hex(16)
      # Explicit selections go first; automatic additions follow in order.
      ids = eligible_scope.order(wanted: :desc, id: :asc).limit(batch_size).pluck(:id)
      return [] if ids.empty?

      HardcoverSubscriptionItem.claimable(now).where(id: ids)
        .update_all(claim_token: token, claimed_at: now, updated_at: now)
      HardcoverSubscriptionItem.where(claim_token: token).includes(subscription: :user).order(wanted: :desc, id: :asc).to_a
    end

    def process(item)
      subscription = item.subscription
      user = subscription.user

      unless item.wanted? || within_automatic_limit?(user)
        release!(item, next_attempt_at: now + AUTOMATIC_DEFER)
        return :deferred
      end

      book_types = (item.book_types.presence || subscription.book_types) & RequestOptionPolicy.book_types_for(ContentKinds::BOOK)
      return fail!(item, "No formats selected for this book") if book_types.empty?

      covered, request_ids = covered_formats(item, book_types)
      missing = book_types - covered
      created_types = []
      errors = []

      if missing.any?
        result = RequestCreationService.call(
          user: user,
          work_id: item.work_id,
          book_types: missing,
          metadata_attrs: item.metadata_attrs,
          origin: { created_via: "hardcover", external_source: "hardcover" },
          lookup_metadata: false
        )
        result.created_requests.each do |request|
          created_types << request.book.book_type
          request_ids << request.id
        end
        errors = result.errors
        # A request created elsewhere in the meantime also satisfies the item.
        late_covered, late_ids = covered_formats(item, missing - created_types)
        created_types.concat(late_covered)
        request_ids.concat(late_ids)
      end

      still_missing = missing - created_types
      if still_missing.any?
        return fail!(item, errors.presence&.join("; ") || "Could not create requests for #{still_missing.join(', ')}",
          request_ids: request_ids)
      end

      @automatic_counts[user.id] += created_types.size unless item.wanted?
      item.update!(
        state: "requested",
        request_ids: (item.request_ids + request_ids).uniq,
        resolution: resolution_text(created_types, covered),
        resolved_at: now,
        last_error: nil,
        claim_token: nil,
        claimed_at: nil,
        last_attempt_at: now,
        attempts: item.attempts + 1
      )
      :requested
    rescue StandardError => e
      Rails.logger.error("[Hardcover::ItemImporter] Item #{item.id} failed: #{e.class}: #{e.message}")
      fail!(item, "Unexpected error: #{e.class.name}")
    end

    def covered_formats(item, book_types)
      covered = []
      request_ids = []
      book_types.each do |book_type|
        check = DuplicateDetectionService.check(work_id: item.work_id, book_type: book_type)
        next unless check.block?

        covered << book_type
        request_ids << check.existing_request.id if check.existing_request
      end
      [ covered, request_ids ]
    end

    def within_automatic_limit?(user)
      @automatic_counts[user.id] < HardcoverIntegration.max_automatic_requests_per_run
    end

    def fail!(item, message, request_ids: [])
      attempts = item.attempts + 1
      retry_at = attempts < HardcoverSubscriptionItem::MAX_AUTOMATIC_ATTEMPTS ? now + (attempts**2 * 10).minutes : nil
      item.update!(
        state: "failed",
        last_error: message.to_s.truncate(500),
        attempts: attempts,
        last_attempt_at: now,
        next_attempt_at: retry_at,
        request_ids: (item.request_ids + request_ids).uniq,
        claim_token: nil,
        claimed_at: nil
      )
      :failed
    end

    def release!(item, next_attempt_at:)
      item.update!(claim_token: nil, claimed_at: nil, next_attempt_at: next_attempt_at)
    end

    def resolution_text(created_types, covered)
      parts = []
      parts << "Requested #{labels(created_types)}" if created_types.any?
      parts << "#{labels(covered)} already in Shelfarr" if covered.any?
      parts.join("; ")
    end

    def labels(book_types)
      book_types.map { |type| RequestOptionPolicy.book_type_label(type).downcase }.to_sentence
    end
  end
end
