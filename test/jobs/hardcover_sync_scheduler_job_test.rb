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

    assert_no_enqueued_jobs
  end
end
