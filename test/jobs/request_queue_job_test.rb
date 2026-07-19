# frozen_string_literal: true

require "test_helper"

class RequestQueueJobTest < ActiveJob::TestCase
  setup do
    @pending_request = requests(:pending_request)
    @not_found_retry_due = requests(:not_found_retry_due)
    @not_found_waiting = requests(:not_found_waiting)
  end

  test "requeues not_found requests that are retry due" do
    assert @not_found_retry_due.not_found?
    assert @not_found_retry_due.next_retry_at <= Time.current

    RequestQueueJob.perform_now

    @not_found_retry_due.reload
    assert @not_found_retry_due.pending?
    assert_nil @not_found_retry_due.next_retry_at
  end

  test "does not requeue not_found requests that are not due yet" do
    assert @not_found_waiting.not_found?
    assert @not_found_waiting.next_retry_at > Time.current

    RequestQueueJob.perform_now

    @not_found_waiting.reload
    assert @not_found_waiting.not_found?
    assert_not_nil @not_found_waiting.next_retry_at
  end

  test "processable scope returns pending requests in FIFO order" do
    # Clear existing pending requests
    Request.pending.destroy_all

    # Create pending requests with specific order
    older_book = Book.create!(title: "Older", book_type: :ebook, open_library_work_id: "OL_OLDER")
    newer_book = Book.create!(title: "Newer", book_type: :ebook, open_library_work_id: "OL_NEWER")

    older_request = Request.create!(book: older_book, user: users(:one), status: :pending, created_at: 2.hours.ago)
    newer_request = Request.create!(book: newer_book, user: users(:one), status: :pending, created_at: 1.hour.ago)

    processable = Request.processable.to_a

    assert processable.index(older_request) < processable.index(newer_request), "Older request should come before newer request"
  end

  test "job processes pending requests limited by batch size" do
    # Clear existing pending requests
    Request.pending.destroy_all

    batch_size = SettingsService.get(:queue_batch_size)

    # Create more pending requests than the batch size
    (batch_size + 2).times do |i|
      book = Book.create!(title: "Batch Test #{i}", book_type: :ebook, open_library_work_id: "OL_BATCH_#{i}")
      Request.create!(book: book, user: users(:one), status: :pending)
    end

    # The job logs which requests would be processed
    # We verify the processable scope respects the limit
    processable = Request.processable.limit(batch_size)
    assert_equal batch_size, processable.count

    # Verify the job runs without error
    assert_nothing_raised { RequestQueueJob.perform_now }
  end

  test "recurring queue execution is serialized" do
    assert_equal 1, RequestQueueJob.concurrency_limit
    assert_equal "request-queue", RequestQueueJob.concurrency_key
    assert_equal :discard, RequestQueueJob.concurrency_on_conflict
  end

  test "pathological queue batch settings cannot enqueue an unbounded run" do
    job = RequestQueueJob.new

    SettingsService.stub(:get, -1) do
      assert_equal 0, job.send(:processing_batch_size)
    end
    SettingsService.stub(:get, 1_000_000) do
      assert_equal RequestQueueJob::MAX_PROCESS_BATCH_SIZE,
        job.send(:processing_batch_size)
    end
  end

  test "recovers a search orphaned after claim and invalidates the killed worker" do
    request = Request.create!(
      book: books(:ebook_pending),
      user: users(:one),
      status: :pending
    )
    killed_job = SearchJob.new
    killed_generation = killed_job.send(:claim_search!, request)
    assert request.reload.search_claimed_at.present?

    travel RequestQueueJob::STALE_SEARCH_LEASE + 1.minute do
      assert_enqueued_with(job: SearchJob, args: [ request.id ]) do
        RequestQueueJob.new.send(:recover_stale_searches)
      end

      request.reload
      assert request.pending?
      assert_nil request.search_claimed_at
      assert_operator request.search_generation, :>, killed_generation
      assert_not killed_job.send(
        :complete_search,
        request,
        killed_generation,
        results: [],
        store_offers: [],
        indexer_error: nil
      )
      assert request.reload.pending?
    end
  end

  test "stale-search recovery leaves a recent legitimate search untouched" do
    request = Request.create!(
      book: books(:ebook_pending),
      user: users(:one),
      status: :pending
    )
    generation = SearchJob.new.send(:claim_search!, request)

    travel RequestQueueJob::STALE_SEARCH_LEASE - 1.minute do
      assert_no_enqueued_jobs only: SearchJob do
        RequestQueueJob.new.send(:recover_stale_searches)
      end

      assert request.reload.searching?
      assert_equal generation, request.search_generation
    end
  end

  test "stale-search recovery rechecks a refreshed claim timestamp under the generation lock" do
    stale_before = Time.current
    request = Request.create!(
      book: books(:ebook_pending),
      user: users(:one),
      status: :searching,
      search_generation: 7,
      search_claimed_at: 1.minute.ago,
      updated_at: 1.minute.ago
    )
    stale_candidate = Request.find(request.id)
    request.update_columns(search_claimed_at: 1.minute.from_now, updated_at: 1.minute.from_now)

    assert_not stale_candidate.recover_stale_search!(stale_before: stale_before)
    assert request.reload.searching?
    assert_equal 7, request.search_generation
  end

  test "stale-search recovery bounds and enqueues each recurring batch" do
    Request.searching.update_all(updated_at: Time.current)
    now = Time.current
    rows = 102.times.map do |index|
      {
        book_id: books(:ebook_pending).id,
        user_id: users(:one).id,
        status: Request.statuses.fetch("searching"),
        search_generation: index + 1,
        search_claimed_at: now - RequestQueueJob::STALE_SEARCH_LEASE - 1.minute,
        notes: "bounded-stale-search-recovery",
        language: "en",
        created_via: "web",
        request_scope: "single",
        created_at: now - 1.hour,
        updated_at: now - RequestQueueJob::STALE_SEARCH_LEASE - 1.minute
      }
    end
    Request.insert_all!(rows)

    assert_enqueued_jobs RequestQueueJob::RECONCILIATION_BATCH_SIZE, only: SearchJob do
      RequestQueueJob.new.send(:recover_stale_searches)
    end

    reconciled = Request.where(notes: "bounded-stale-search-recovery")
    assert_equal 100, reconciled.pending.count
    assert_equal 2, reconciled.searching.count
    assert_equal (2..101).to_a,
      reconciled.pending.order(:search_generation).pluck(:search_generation)
  end

  test "an enqueue failure leaves stale-search recovery eligible for the next pending pass" do
    request = Request.create!(
      book: books(:ebook_pending),
      user: users(:one),
      status: :searching,
      search_generation: 3,
      search_claimed_at: RequestQueueJob::STALE_SEARCH_LEASE.ago - 1.minute,
      updated_at: RequestQueueJob::STALE_SEARCH_LEASE.ago - 1.minute
    )
    failed_enqueues = 0
    failure = lambda do |*|
      failed_enqueues += 1
      raise ActiveJob::EnqueueError, "simulated queue outage"
    end

    SearchJob.stub(:perform_later, failure) do
      assert_nothing_raised { RequestQueueJob.new.send(:recover_stale_searches) }
    end

    assert_equal 1, failed_enqueues
    assert request.reload.pending?
    assert_equal 4, request.search_generation
    assert_enqueued_with(job: SearchJob, args: [ request.id ]) do
      RequestQueueJob.new.send(:process_pending_requests)
    end
  end

  test "does not recover a completed search awaiting manual selection" do
    request = Request.create!(
      book: books(:ebook_pending),
      user: users(:one),
      status: :searching,
      search_generation: 3,
      search_claimed_at: nil,
      attention_needed: true,
      issue_description: "Search results found. Please review and select a result.",
      updated_at: RequestQueueJob::STALE_SEARCH_LEASE.ago - 1.minute
    )
    result = request.search_results.create!(
      guid: "completed-manual-review-search",
      title: "Completed manual review result",
      magnet_url: "magnet:?xt=urn:btih:#{'f' * 40}"
    )

    assert_no_enqueued_jobs only: SearchJob do
      RequestQueueJob.new.send(:recover_stale_searches)
    end

    assert request.reload.searching?
    assert request.attention_needed?
    assert_nil request.search_claimed_at
    assert SearchResult.exists?(result.id)
  end

  test "retry reconciliation bounds each recurring run" do
    Request.retry_due.update_all(next_retry_at: 1.hour.from_now)
    now = Time.current
    rows = 102.times.map do
      {
        book_id: books(:ebook_pending).id,
        user_id: users(:one).id,
        status: Request.statuses.fetch("not_found"),
        next_retry_at: 1.minute.ago,
        notes: "bounded-retry-reconciliation",
        language: "en",
        created_via: "web",
        request_scope: "single",
        created_at: now,
        updated_at: now
      }
    end
    Request.insert_all!(rows)

    RequestQueueJob.new.send(:requeue_retry_due_requests)

    reconciled = Request.where(notes: "bounded-retry-reconciliation")
    assert_equal 100, reconciled.pending.count
    assert_equal 2, reconciled.not_found.count
  end

  test "expired offer reconciliation bounds each recurring run" do
    SettingsService.set(:ebooks_com_enabled, false)
    now = Time.current
    rows = 102.times.map do
      {
        book_id: books(:ebook_pending).id,
        user_id: users(:one).id,
        status: Request.statuses.fetch("awaiting_purchase"),
        notes: "bounded-offer-reconciliation",
        language: "en",
        created_via: "web",
        request_scope: "single",
        created_at: now,
        updated_at: now
      }
    end
    Request.insert_all!(rows)

    RequestQueueJob.new.send(:requeue_requests_without_visible_store_offers)

    reconciled = Request.where(notes: "bounded-offer-reconciliation")
    assert_equal 100, reconciled.pending.count
    assert_equal 2, reconciled.awaiting_purchase.count
  end

  test "requeues an awaiting purchase request after its store quote expires" do
    SettingsService.set(:ebooks_com_enabled, true)
    SettingsService.set(:ebooks_com_country_code, "PT")
    request = requests(:pending_request)
    request.update!(status: :awaiting_purchase)
    request.store_offers.create!(
      provider: "ebooks_com",
      external_id: "expired-queue-offer",
      title: request.book.title,
      formats: [ "epub" ],
      market: "PT",
      drm_free: true,
      storefront_url: "https://www.ebooks.com/en-pt/book/expired-queue-offer/expired/",
      quoted_at: StoreOffer::FRESHNESS_TTL.ago - 1.minute
    )
    RequestEvent.record_latest!(
      request: request,
      event_type: "store_offers_found",
      source: "store_provider",
      message: "1 DRM-free store offer found"
    )

    RequestQueueJob.perform_now

    assert request.reload.pending?
    assert_empty request.store_offers
    assert_nil request.request_events.find_by(event_type: "store_offers_found", source: "store_provider")
  ensure
    SettingsService.set(:ebooks_com_enabled, false)
    SettingsService.set(:ebooks_com_country_code, "")
  end

  test "preserves an awaiting purchase request while its quote is fresh" do
    SettingsService.set(:ebooks_com_enabled, true)
    SettingsService.set(:ebooks_com_country_code, "PT")
    request = requests(:pending_request)
    request.update!(status: :awaiting_purchase)
    request.store_offers.create!(
      provider: "ebooks_com",
      external_id: "fresh-queue-offer",
      title: request.book.title,
      formats: [ "epub" ],
      market: "PT",
      drm_free: true,
      storefront_url: "https://www.ebooks.com/en-pt/book/fresh-queue-offer/fresh/",
      quoted_at: Time.current
    )

    RequestQueueJob.perform_now

    assert request.reload.awaiting_purchase?
  ensure
    SettingsService.set(:ebooks_com_enabled, false)
    SettingsService.set(:ebooks_com_country_code, "")
  end
end
