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
  #
  # A claimed batch is not a promise to import it. Right before each item's
  # requests are created, the item, its subscription, the user, the feature
  # switch, and (for personal subscriptions) the connected account are read
  # again inside the same transaction that creates the requests. Pausing,
  # disconnecting, deleting the user, or disabling Hardcover therefore stops
  # the rest of the batch; those items keep their place in the queue and run
  # after a deliberate resume.
  class ItemImporter
    BATCH_SIZE = 25
    AUTOMATIC_DEFER = 15.minutes
    # Pause between items, outside any transaction. A pause or disconnect
    # waiting on the database lock gets in here instead of losing the race to
    # the next item's transaction.
    ITEM_GAP = 0.05

    Result = Data.define(:processed, :requested, :failed, :deferred, :remaining, :cancelled) do
      def initialize(processed:, requested:, failed:, deferred:, remaining:, cancelled: 0)
        super
      end
    end

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

      requested = failed = deferred = cancelled = 0
      items = claim_batch
      items.each_with_index do |item, index|
        sleep(item_gap) if index.positive? && item_gap.positive?
        case process(item)
        when :requested then requested += 1
        when :failed then failed += 1
        when :deferred then deferred += 1
        when :cancelled then cancelled += 1
        end
      end

      HardcoverSubscription.where(id: items.map(&:hardcover_subscription_id).uniq).find_each(&:broadcast_progress)
      Result.new(processed: items.size, requested: requested, failed: failed, deferred: deferred,
        remaining: eligible_scope.count, cancelled: cancelled)
    end

    private

    attr_reader :batch_size, :now

    # The test environment sets this to zero so suites do not sleep.
    def item_gap
      configured = Rails.configuration.x.hardcover_import_item_gap
      configured.nil? ? ITEM_GAP : configured.to_f
    end

    def eligible_scope
      HardcoverSubscriptionItem.claimable(now)
        .joins(subscription: :user)
        .where(hardcover_subscriptions: { status: "active" })
        .where(users: { deleted_at: nil })
    end

    def claim_batch
      @token = SecureRandom.hex(16)
      # Explicit selections go first; automatic additions follow in order.
      ids = eligible_scope.order(wanted: :desc, id: :asc).limit(batch_size).pluck(:id)
      return [] if ids.empty?

      HardcoverSubscriptionItem.claimable(now).where(id: ids)
        .update_all(claim_token: @token, claimed_at: now, updated_at: now)
      HardcoverSubscriptionItem.where(claim_token: @token).order(wanted: :desc, id: :asc).to_a
    end

    # The eligibility check and the request creation share one transaction.
    # On SQLite it is an IMMEDIATE (write) transaction, and elsewhere the
    # subscription row is locked, so a pause or disconnect either lands
    # before the check (and the item waits) or after the requests exist.
    def process(item)
      outcome = nil
      HardcoverSubscriptionItem.transaction do
        current = HardcoverSubscriptionItem.lock.find_by(id: item.id, claim_token: @token)
        if current.nil? || !current.queued?
          outcome = :skipped
        elsif (subscription = eligible_subscription(current))
          outcome = import(current, subscription)
        else
          release!(current)
          outcome = :cancelled
        end
      end
      outcome
    rescue StandardError => e
      Rails.logger.error("[Hardcover::ItemImporter] Item #{item.id} failed: #{e.class}: #{e.message}")
      current = HardcoverSubscriptionItem.find_by(id: item.id, claim_token: @token)
      current ? fail!(current, "Unexpected error: #{e.class.name}") : :skipped
    end

    def eligible_subscription(item)
      return unless HardcoverIntegration.enabled?

      subscription = HardcoverSubscription.lock.find_by(id: item.hardcover_subscription_id)
      return unless subscription&.active?

      user = User.find_by(id: subscription.user_id)
      return if user.nil? || user.deleted?

      if subscription.requires_connection?
        connection = HardcoverConnection.find_by(user_id: user.id)
        unless connection&.usable? && subscription.owned_by_connection?(connection)
          # Pausing keeps the rest of the queue waiting for a deliberate
          # resume instead of being claimed and released on every run.
          reason = connection&.usable? ? HardcoverSubscription::PAUSE_OTHER_ACCOUNT : HardcoverSubscription::PAUSE_RECONNECT
          subscription.pause!(reason)
          return
        end
      end

      subscription.user = user
      subscription
    end

    def import(item, subscription)
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

    # Keeps the item queued without a claim. Cancelled items keep no delay,
    # so they run as soon as the subscription is resumed.
    def release!(item, next_attempt_at: item.next_attempt_at)
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
