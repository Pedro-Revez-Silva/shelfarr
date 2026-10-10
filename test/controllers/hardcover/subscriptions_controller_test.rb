# frozen_string_literal: true

require "test_helper"

class Hardcover::SubscriptionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:one)
    sign_in_as(@user)
    configure_hardcover_instance_token
  end

  test "previewing a list creates a draft and loads it in the background without requesting anything" do
    stub_hardcover_graphql("ShelfarrList" => { "lists" => [ { "id" => 77, "name" => "Space Opera", "slug" => "space-opera", "books_count" => 2, "likes_count" => 3,
      "privacy_setting_id" => 1, "user" => { "username" => "curator" } } ] })

    assert_no_difference -> { Request.count } do
      assert_enqueued_with(job: HardcoverSubscriptionSyncJob) do
        post hardcover_subscriptions_path, params: { kind: "list", hardcover_target_id: 77 }
      end
    end

    subscription = @user.hardcover_subscriptions.find_by!(target_key: "list:77")
    assert_redirected_to hardcover_subscription_path(subscription)
    assert subscription.draft?
    assert_equal [ "Space Opera", "curator" ], [ subscription.title, subscription.owner_username ]
  end

  test "following an author resolves a duplicate author record to its canonical author" do
    stub_hardcover_graphql("ShelfarrAuthor" => ->(variables) do
      if variables["id"] == 900
        { "authors" => [ { "id" => 900, "name" => "Dup Author", "canonical_id" => 901 } ] }
      else
        { "authors" => [ { "id" => 901, "name" => "Real Author", "slug" => "real-author", "canonical_id" => nil } ] }
      end
    end)

    post hardcover_subscriptions_path, params: { kind: "author", hardcover_target_id: 900 }

    subscription = @user.hardcover_subscriptions.sole
    assert_equal [ 901, "Real Author", "author:901" ], [ subscription.hardcover_target_id, subscription.title, subscription.target_key ]
  end

  test "invalid targets are rejected before calling Hardcover" do
    post hardcover_subscriptions_path, params: { kind: "list", hardcover_target_id: "abc" }
    assert_redirected_to hardcover_subscriptions_path

    post hardcover_subscriptions_path, params: { kind: "shelf" }
    assert_redirected_to hardcover_subscriptions_path

    assert_equal 0, @user.hardcover_subscriptions.count
    assert_not_requested :post, HardcoverClient::BASE_URL
  end

  test "Want to Read requires the user's own connection" do
    post hardcover_subscriptions_path, params: { kind: "want_to_read" }

    assert_redirected_to profile_path
    assert_equal 0, @user.hardcover_subscriptions.count
  end

  test "users cannot see or change another user's subscriptions" do
    other = create_hardcover_subscription(users(:two), kind: "list", status: "draft")
    item = create_hardcover_item(other, book_id: 1)

    get hardcover_subscription_path(other)
    assert_redirected_to hardcover_subscriptions_path

    patch hardcover_subscription_path(other), params: { book_types: [ "ebook" ], item_ids: [ item.id ] }
    post request_items_hardcover_subscription_path(other), params: { book_types: [ "ebook" ], item_ids: [ item.id ] }
    delete hardcover_subscription_path(other)
    post item_hardcover_subscription_path(other, item_id: item.id, item_action: "ignore")

    assert other.reload.draft?
    assert_equal "known", item.reload.state
  end

  test "items from another subscription cannot be queued through mine" do
    mine = create_hardcover_subscription(@user, kind: "list", target_id: 1)
    theirs = create_hardcover_subscription(users(:two), kind: "list", target_id: 1)
    foreign = create_hardcover_item(theirs, book_id: 5)

    post request_items_hardcover_subscription_path(mine), params: { book_types: [ "ebook" ], item_ids: [ foreign.id ] }

    assert_equal "known", foreign.reload.state
  end

  test "the preview shows per-format status and confirming queues only the selected books" do
    subscription = create_hardcover_subscription(@user, kind: "list", status: "draft")
    selected = create_hardcover_item(subscription, book_id: 11, title: "Selected Book")
    skipped = create_hardcover_item(subscription, book_id: 12, title: "Skipped Book")
    upcoming = create_hardcover_item(subscription, book_id: 13, title: "Future Book", state: "upcoming", release_date: 1.month.from_now.to_date)
    Book.create!(title: "Selected Book", hardcover_id: "11", book_type: :ebook, file_path: "/ebooks/selected.epub")

    get hardcover_subscription_path(subscription)
    assert_response :success
    assert_select "span", text: "Ebook: In library"
    assert_select "span", text: "Audiobook: Not requested"
    assert_select "input[type=submit][value='Follow and request selected']"

    assert_no_difference -> { Request.count } do
      assert_enqueued_with(job: HardcoverImportJob) do
        patch hardcover_subscription_path(subscription), params: {
          book_types: %w[ebook audiobook], automatic: "1", item_ids: [ selected.id, upcoming.id ]
        }
      end
    end

    subscription.reload
    assert subscription.active?
    assert subscription.automatic?
    assert_equal %w[ebook audiobook], subscription.book_types
    assert_equal subscription.snapshot_completed_at.to_i, subscription.baseline_established_at.to_i
    assert_equal [ "queued", %w[ebook audiobook] ], [ selected.reload.state, selected.book_types ]
    assert_equal "known", skipped.reload.state
    assert_equal "upcoming", upcoming.reload.state
    assert upcoming.wanted?, "a selected upcoming book is requested on release"
  end

  test "confirm can request every released book explicitly" do
    subscription = create_hardcover_subscription(@user, kind: "list", status: "draft")
    known = create_hardcover_item(subscription, book_id: 21)
    ignored = create_hardcover_item(subscription, book_id: 22, state: "ignored")
    upcoming = create_hardcover_item(subscription, book_id: 23, state: "upcoming", release_date: 1.month.from_now.to_date)

    patch hardcover_subscription_path(subscription), params: { book_types: [ "ebook" ], automatic: "0", select_all: "1" }

    assert_equal "queued", known.reload.state
    assert_equal "ignored", ignored.reload.state
    assert_equal "upcoming", upcoming.reload.state
    assert_not subscription.reload.automatic?
  end

  test "formats are validated on the server" do
    subscription = create_hardcover_subscription(@user, kind: "list", status: "draft")
    item = create_hardcover_item(subscription, book_id: 31)

    patch hardcover_subscription_path(subscription), params: { book_types: [ "comicbook" ], item_ids: [ item.id ] }
    assert_match(/at least one format/, flash[:alert])

    patch hardcover_subscription_path(subscription), params: { book_types: [ "ebook", "../../etc" ], item_ids: [ item.id ] }
    assert_match(/at least one format/, flash[:alert])

    assert subscription.reload.draft?
    assert_equal "known", item.reload.state
  end

  test "a preview that is still loading cannot be confirmed" do
    subscription = create_hardcover_subscription(@user, kind: "list", status: "draft")
    subscription.update!(snapshot_state: "loading")

    patch hardcover_subscription_path(subscription), params: { book_types: [ "ebook" ] }

    assert subscription.reload.draft?
    assert_match(/finish loading/, flash[:alert])
  end

  test "requesting selected books on a followed subscription queues them" do
    subscription = create_hardcover_subscription(@user, kind: "author", target_id: 3)
    pending = create_hardcover_item(subscription, book_id: 41, state: "pending")
    requested = create_hardcover_item(subscription, book_id: 42, state: "requested")

    post request_items_hardcover_subscription_path(subscription), params: { book_types: [ "audiobook" ], item_ids: [ pending.id, requested.id ] }

    assert_equal [ "queued", [ "audiobook" ] ], [ pending.reload.state, pending.book_types ]
    assert_equal "requested", requested.reload.state
  end

  test "stopping a subscription keeps the requests it created" do
    subscription = create_hardcover_subscription(@user, kind: "list")
    request = Request.create!(user: @user, book: Book.create!(title: "Kept", hardcover_id: "51", book_type: :ebook), created_via: "hardcover")
    create_hardcover_item(subscription, book_id: 51, state: "requested", request_ids: [ request.id ])

    delete hardcover_subscription_path(subscription)

    assert_redirected_to hardcover_subscriptions_path
    assert_not HardcoverSubscription.exists?(subscription.id)
    assert Request.exists?(request.id)
  end

  test "item actions dismiss, restore, and retry" do
    subscription = create_hardcover_subscription(@user, kind: "list")
    item = create_hardcover_item(subscription, book_id: 61, state: "pending")

    post item_hardcover_subscription_path(subscription, item_id: item.id, item_action: "ignore")
    assert_equal "ignored", item.reload.state
    post item_hardcover_subscription_path(subscription, item_id: item.id, item_action: "restore")
    assert_equal "pending", item.reload.state

    item.update!(state: "failed", attempts: 5, last_error: "boom")
    assert_enqueued_with(job: HardcoverImportJob) do
      post item_hardcover_subscription_path(subscription, item_id: item.id, item_action: "retry")
    end
    assert_equal [ "queued", 0 ], [ item.reload.state, item.attempts ]
  end

  test "manual checks are rate limited" do
    subscription = create_hardcover_subscription(@user, kind: "list")
    subscription.update!(last_synced_at: 1.minute.ago)

    assert_no_enqueued_jobs(only: HardcoverSubscriptionSyncJob) do
      post refresh_hardcover_subscription_path(subscription)
    end
  end

  test "pausing and resuming" do
    subscription = create_hardcover_subscription(@user, kind: "list")

    post pause_hardcover_subscription_path(subscription)
    assert subscription.reload.paused?

    post resume_hardcover_subscription_path(subscription)
    assert subscription.reload.active?
  end

  test "the following page lists the user's Hardcover shelves and lists when connected" do
    create_hardcover_connection(@user)
    create_hardcover_subscription(@user, kind: "author", target_id: 8, title: "Followed Author")
    create_hardcover_subscription(users(:two), kind: "author", target_id: 9, title: "Someone Else's Author")
    stub_hardcover_graphql("ShelfarrUserLists" => { "lists" => [ { "id" => 5, "name" => "My Private Picks", "books_count" => 4, "privacy_setting_id" => 3 } ] })

    get hardcover_subscriptions_path

    assert_response :success
    assert_includes response.body, "My Private Picks"
    assert_includes response.body, "Followed Author"
    assert_not_includes response.body, "Someone Else&#39;s Author"
    assert_equal "Bearer hc_at_test_#{@user.id}", hardcover_requests.last[:authorization]
  end
end
