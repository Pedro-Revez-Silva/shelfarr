# frozen_string_literal: true

require "test_helper"

class HardcoverSyncSchedulerJobTest < ActiveJob::TestCase
  setup do
    SettingsService.set(:hardcover_enabled, true)
    @user = users(:one)
  end

  test "released upcoming books move to the import queue or to review" do
    automatic = create_hardcover_subscription(@user, kind: "author", target_id: 1, automatic: true, book_types: [ "audiobook" ])
    manual = create_hardcover_subscription(@user, kind: "author", target_id: 2, automatic: false)
    released_auto = create_hardcover_item(automatic, book_id: 1, state: "upcoming", release_date: Date.yesterday)
    released_wanted = create_hardcover_item(manual, book_id: 2, state: "upcoming", release_date: Date.current, wanted: true, book_types: [ "ebook" ])
    released_manual = create_hardcover_item(manual, book_id: 3, state: "upcoming", release_date: Date.yesterday)
    still_upcoming = create_hardcover_item(automatic, book_id: 4, state: "upcoming", release_date: Date.tomorrow)

    HardcoverSyncSchedulerJob.perform_now

    assert_equal [ "queued", [ "audiobook" ] ], [ released_auto.reload.state, released_auto.book_types ]
    assert_equal [ "queued", [ "ebook" ] ], [ released_wanted.reload.state, released_wanted.book_types ]
    assert_equal "pending", released_manual.reload.state
    assert_equal "upcoming", still_upcoming.reload.state
    assert_enqueued_with(job: HardcoverImportJob)
  end

  test "an automatic list requests released books added after its baseline but not ones that were already there" do
    list = create_hardcover_subscription(@user, kind: "list", target_id: 7, automatic: true)
    added_later = create_hardcover_item(list, book_id: 11, state: "upcoming", release_date: Date.yesterday, baseline: false)
    already_there = create_hardcover_item(list, book_id: 12, state: "upcoming", release_date: Date.yesterday, baseline: true)
    selected = create_hardcover_item(list, book_id: 13, state: "upcoming", release_date: Date.yesterday, baseline: true, wanted: true, book_types: [ "audiobook" ])
    manual_author = create_hardcover_subscription(@user, kind: "author", target_id: 8)
    author_backlist = create_hardcover_item(manual_author, book_id: 14, state: "upcoming", release_date: Date.yesterday, baseline: true)

    HardcoverSyncSchedulerJob.perform_now

    assert_equal [ "queued", [ "ebook" ] ], [ added_later.reload.state, added_later.book_types ]
    assert_equal "known", already_there.reload.state
    assert_equal [ "queued", [ "audiobook" ] ], [ selected.reload.state, selected.book_types ]
    assert_equal "pending", author_backlist.reload.state, "authors offer released books for review when automatic requests are off"
  end

  # Streams that would get a page refresh, without Turbo's debounce timer.
  def capture_refreshes(&block)
    streams = []
    Turbo::StreamsChannel.stub(:broadcast_refresh_later_to, ->(*streamables, **) { streams << streamables }, &block)
    streams
  end

  test "open subscription pages refresh once when the schedule changes their items, not on quiet runs" do
    shelf = create_hardcover_subscription(@user, kind: "list", target_id: 21, automatic: true)
    author = create_hardcover_subscription(@user, kind: "author", target_id: 22)
    unchanged = create_hardcover_subscription(@user, kind: "list", target_id: 23)
    known = create_hardcover_item(shelf, book_id: 31, state: "upcoming", release_date: Date.yesterday, baseline: true)
    retried = create_hardcover_item(shelf, book_id: 32, state: "failed", attempts: 1, next_attempt_at: 1.minute.ago)
    pending = [ 33, 34 ].map { |id| create_hardcover_item(author, book_id: id, state: "upcoming", release_date: Date.yesterday) }
    create_hardcover_item(unchanged, book_id: 35, state: "upcoming", release_date: Date.tomorrow)

    streams = capture_refreshes { HardcoverSyncSchedulerJob.perform_now }

    assert_equal [ "known", "queued", %w[pending pending] ], [ known.reload.state, retried.reload.state, pending.map { |item| item.reload.state } ]
    assert_equal [ [ author ], [ shelf ] ].sort_by { |(subscription)| subscription.id }, streams.sort_by { |(subscription)| subscription.id }
    assert_empty capture_refreshes { HardcoverSyncSchedulerJob.perform_now }, "a run that changes nothing sends nothing"
  end

  test "failed imports are retried after their backoff, up to the attempt limit" do
    subscription = create_hardcover_subscription(@user)
    due = create_hardcover_item(subscription, book_id: 1, state: "failed", attempts: 1, next_attempt_at: 1.minute.ago)
    waiting = create_hardcover_item(subscription, book_id: 2, state: "failed", attempts: 1, next_attempt_at: 1.hour.from_now)
    exhausted = create_hardcover_item(subscription, book_id: 3, state: "failed", attempts: HardcoverSubscriptionItem::MAX_AUTOMATIC_ATTEMPTS, next_attempt_at: nil)

    HardcoverSyncSchedulerJob.perform_now

    assert_equal %w[queued failed failed], [ due, waiting, exhausted ].map { |item| item.reload.state }
  end

  test "enqueues due active subscriptions and removes abandoned previews" do
    due = create_hardcover_subscription(@user, kind: "list", target_id: 1)
    due.update!(next_sync_at: 1.minute.ago)
    later = create_hardcover_subscription(@user, kind: "list", target_id: 2)
    later.update!(next_sync_at: 1.hour.from_now)
    paused = create_hardcover_subscription(@user, kind: "list", target_id: 3)
    paused.update!(status: "paused", next_sync_at: 1.minute.ago)
    stale_draft = create_hardcover_subscription(@user, kind: "list", target_id: 4, status: "draft")
    stale_draft.update_column(:updated_at, 8.days.ago)
    fresh_draft = create_hardcover_subscription(@user, kind: "list", target_id: 5, status: "draft")

    HardcoverSyncSchedulerJob.perform_now

    assert_enqueued_with(job: HardcoverSubscriptionSyncJob, args: [ due.id ])
    assert_enqueued_jobs 1, only: HardcoverSubscriptionSyncJob
    assert_not HardcoverSubscription.exists?(stale_draft.id)
    assert HardcoverSubscription.exists?(fresh_draft.id)
    assert HardcoverSubscription.exists?(paused.id)
    assert HardcoverSubscription.exists?(later.id)
  end

  test "does nothing while Hardcover is disabled" do
    subscription = create_hardcover_subscription(@user)
    subscription.update!(next_sync_at: 1.minute.ago)
    SettingsService.set(:hardcover_enabled, false)

    HardcoverSyncSchedulerJob.perform_now

    # Scoped to the scheduler's own jobs: Turbo enqueues debounced refresh
    # broadcasts from an earlier test on a timer thread.
    assert_no_enqueued_jobs(only: [ HardcoverSubscriptionSyncJob, HardcoverImportJob ])
  end
end
