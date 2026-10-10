# frozen_string_literal: true

require "test_helper"

class HardcoverSubscriptionSyncJobTest < ActiveJob::TestCase
  setup do
    SettingsService.set(:hardcover_enabled, true)
    @user = users(:one)
  end

  test "a preview loads entries and enqueues no imports" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list", status: "draft")
    stub_hardcover_graphql("ShelfarrListBooks" => { "list_books" => [ hardcover_list_book_row(hardcover_book(id: 1), id: 1) ] })

    assert_no_enqueued_jobs(only: HardcoverImportJob) do
      HardcoverSubscriptionSyncJob.perform_now(subscription.id, mode: "snapshot")
    end

    assert_equal "ready", subscription.reload.snapshot_state
    assert_equal 1, subscription.items.count
  end

  test "new automatic additions enqueue the import job" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list", automatic: true)
    stub_hardcover_graphql("ShelfarrListBooksSince" => { "list_books" => [ hardcover_list_book_row(hardcover_book(id: 2), id: 2, date_added: 1.minute.ago.iso8601) ] })

    assert_enqueued_with(job: HardcoverImportJob) do
      HardcoverSubscriptionSyncJob.perform_now(subscription.id)
    end
  end

  test "a rate limit backs off to Hardcover's retry time without touching items" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list")
    item = create_hardcover_item(subscription, book_id: 3, state: "known")
    stub_request(:post, HardcoverClient::BASE_URL).to_return(status: 429, headers: { "Retry-After" => "3600" }, body: "{}")

    HardcoverSubscriptionSyncJob.perform_now(subscription.id)

    subscription.reload
    assert_operator subscription.next_sync_at, :>, 50.minutes.from_now
    assert_equal 1, subscription.consecutive_failures
    assert_match(/rate limit/i, subscription.last_error)
    assert_equal "known", item.reload.state
  ensure
    HardcoverClient.send(:local_rate_limit_deadlines).clear
  end

  test "a failed preview is reported on the subscription" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list", status: "draft")
    stub_request(:post, HardcoverClient::BASE_URL).to_return(status: 500, body: "{}")

    HardcoverSubscriptionSyncJob.perform_now(subscription.id, mode: "snapshot")

    assert_equal "failed", subscription.reload.snapshot_state
    assert subscription.last_error.present?
  end

  test "Want to Read pauses when the account connection is gone" do
    subscription = create_hardcover_subscription(@user, kind: "want_to_read")

    HardcoverSubscriptionSyncJob.perform_now(subscription.id)

    assert subscription.reload.paused?
    assert_not_requested :post, HardcoverClient::BASE_URL
  end

  test "Want to Read pauses when Hardcover rejects the user's token" do
    connection = create_hardcover_connection(@user, auth_method: "personal_token", access_token: "hc_pat")
    subscription = create_hardcover_subscription(@user, kind: "want_to_read")
    stub_request(:post, HardcoverClient::BASE_URL).to_return(status: 401, body: "{}")

    HardcoverSubscriptionSyncJob.perform_now(subscription.id)

    assert subscription.reload.paused?
    assert_equal "reauthorization_required", connection.reload.status
  end

  test "paused subscriptions, deleted users, and a disabled provider are skipped" do
    subscription = create_hardcover_subscription(@user, kind: "list")
    subscription.pause!("Paused by you.")
    HardcoverSubscriptionSyncJob.perform_now(subscription.id)

    subscription.resume!
    SettingsService.set(:hardcover_enabled, false)
    HardcoverSubscriptionSyncJob.perform_now(subscription.id)

    assert_not_requested :post, HardcoverClient::BASE_URL
  end

  test "a scheduled run completes a manual check that was folded into it" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "author", target_id: 501)
    subscription.update!(snapshot_state: "pending")
    stub_hardcover_graphql("ShelfarrAuthorContributions" => { "contributions" => [] })

    HardcoverSubscriptionSyncJob.perform_now(subscription.id)

    assert_equal "ready", subscription.reload.snapshot_state
  end

  test "a failed scheduled run does not leave a manual check loading forever" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list")
    subscription.update!(snapshot_state: "pending")
    stub_request(:post, HardcoverClient::BASE_URL).to_return(status: 500, body: "{}")

    HardcoverSubscriptionSyncJob.perform_now(subscription.id)

    assert_equal "failed", subscription.reload.snapshot_state
  end
end
