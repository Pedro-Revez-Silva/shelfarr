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
    stub_hardcover_graphql("ShelfarrPublicList" => { "lists" => [ { "id" => 77, "name" => "Space Opera", "slug" => "space-opera", "books_count" => 2, "likes_count" => 3,
      "privacy_setting_id" => 1, "public" => true, "user_id" => 31, "user" => { "username" => "curator" } } ] })

    assert_no_difference -> { Request.count } do
      assert_enqueued_with(job: HardcoverSubscriptionSyncJob) do
        post hardcover_subscriptions_path, params: { kind: "list", hardcover_target_id: 77 }
      end
    end

    subscription = @user.hardcover_subscriptions.find_by!(target_key: "list:77")
    assert_redirected_to hardcover_subscription_path(subscription)
    assert subscription.draft?
    assert_equal [ "Space Opera", "curator" ], [ subscription.title, subscription.owner_username ]
    assert_not subscription.personal?, "a public list can be read by anyone"
    assert_equal 31, subscription.hardcover_account_id
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
    assert_in_delta Time.current, subscription.automatic_enabled_at, 5
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

  def requested_formats(book_id)
    Request.joins(:book).where(books: { hardcover_id: book_id.to_s }).order(:id).map { |request| request.book.book_type }
  end

  test "turning automatic requests off stops what they started and leaves it for review" do
    SettingsService.set(:immediate_search_enabled, false)
    SettingsService.set(:hardcover_max_requests_per_run, 1)
    subscription = create_hardcover_subscription(@user, kind: "list", target_id: 77, automatic: true, book_types: %w[ebook audiobook])
    stub_hardcover_graphql("ShelfarrPublicListBooksSince" => { "list_books" => [
      hardcover_list_book_row(hardcover_book(id: 901), id: 1, date_added: 1.hour.ago.iso8601)
    ] })
    HardcoverSubscriptionSyncJob.perform_now(subscription.id)
    HardcoverImportJob.perform_now
    item = subscription.items.find_by!(hardcover_book_id: 901)
    assert_equal [ "queued", [ "ebook" ], [ "ebook" ] ], [ item.state, requested_formats(901), item.settled_book_types ]
    failed = create_hardcover_item(subscription, book_id: 902, state: "failed", book_types: [ "ebook" ], attempts: 1,
      next_attempt_at: 5.minutes.from_now, last_error: "boom")
    selected = create_hardcover_item(subscription, book_id: 903, state: "queued", wanted: true, book_types: [ "audiobook" ],
      next_attempt_at: 1.hour.from_now)

    patch hardcover_subscription_path(subscription), params: { book_types: %w[ebook audiobook], automatic: "0" }

    assert_redirected_to hardcover_subscription_path(subscription)
    assert_match(/1 book waiting for an automatic request moved to New/, flash[:notice])
    assert_not subscription.reload.automatic?
    item.reload
    assert_equal [ "pending", %w[ebook audiobook], [ "ebook" ], nil ], [ item.state, item.book_types, item.settled_book_types, item.next_attempt_at ]
    assert_equal [ "failed", nil, "boom" ], [ failed.reload.state, failed.next_attempt_at, failed.last_error ]
    assert_equal "queued", selected.reload.state, "a book the user selected is still requested"
    Request.find(item.request_ids.sole).schedule_retry!

    travel 7.hours do
      assert_difference -> { Request.count } => 1 do
        HardcoverSyncSchedulerJob.perform_now
        HardcoverImportJob.perform_now
      end
      assert_equal [ "audiobook" ], requested_formats(903)
      assert_equal [ "pending", "failed" ], [ item.reload.state, failed.reload.state ]
    end

    patch hardcover_subscription_path(subscription), params: { book_types: %w[ebook audiobook], automatic: "1" }
    assert_equal "Settings saved.", flash[:notice]
    assert_equal "pending", item.reload.state, "turning it back on only applies to later additions"

    # Selecting the book requests the format still missing, not the ebook again.
    post request_items_hardcover_subscription_path(subscription), params: { book_types: %w[ebook audiobook], item_ids: [ item.id ] }
    assert_difference -> { Request.count } => 1 do
      HardcoverImportJob.perform_now
    end
    assert_equal %w[ebook audiobook], requested_formats(901)
    assert_equal [ "requested", %w[audiobook ebook] ], [ item.reload.state, item.settled_book_types.sort ]
  end

  test "turning automatic requests off while a batch runs stops its automatic items" do
    SettingsService.set(:immediate_search_enabled, false)
    subscription = create_hardcover_subscription(@user, kind: "list", target_id: 77, automatic: true, book_types: [ "ebook" ])
    selected = create_hardcover_item(subscription, book_id: 911, state: "queued", wanted: true, book_types: [ "ebook" ])
    automatic = [ 912, 913 ].map { |id| create_hardcover_item(subscription, book_id: id, state: "queued", book_types: [ "ebook" ]) }
    original = RequestCreationService.method(:call)
    changed = false
    creator = lambda do |**args|
      original.call(**args).tap do
        next if changed || args[:work_id] != selected.work_id

        changed = true
        patch hardcover_subscription_path(subscription), params: { book_types: [ "ebook" ], automatic: "0" }
      end
    end

    assert_difference -> { Request.count } => 1 do
      RequestCreationService.stub(:call, creator) { HardcoverImportJob.perform_now }
    end

    assert changed
    assert_equal "requested", selected.reload.state
    assert_equal %w[pending pending], automatic.map { |item| item.reload.state }
    assert automatic.all? { |item| item.claim_token.nil? }
    assert_no_enqueued_jobs(only: HardcoverImportJob)
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
    assert_equal [ "queued", 0, true ], [ item.reload.state, item.attempts, item.wanted? ], "a retry is the user's request"
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

  PRIVATE_LIST = { "name" => "Owner's secret shelf", "slug" => "secret", "books_count" => 1, "likes_count" => 0,
    "privacy_setting_id" => 3, "user_id" => 1_001, "user" => { "username" => "owner" } }.freeze

  def private_list_provider
    stub_hardcover_list_visibility(
      lists: { 77 => PRIVATE_LIST },
      books: { 77 => [ hardcover_list_book_row(hardcover_book(id: 9_001, title: "Secret owner book"), id: 1) ] },
      accounts: { "owner_token" => 1_001, "viewer_token" => 2_002, "instance_test_token" => 1_001 }
    )
  end

  test "only the owner can follow a private list, and only with their own connection" do
    configure_hardcover_instance_token("owner_token")
    create_hardcover_connection(@user, hardcover_user_id: 1_001, access_token: "owner_token", username: "owner")
    private_list_provider

    post hardcover_subscriptions_path, params: { kind: "list", hardcover_target_id: 77 }
    subscription = @user.hardcover_subscriptions.find_by!(target_key: "list:77")
    assert subscription.personal?
    assert_equal 1_001, subscription.hardcover_account_id
    perform_enqueued_jobs(only: HardcoverSubscriptionSyncJob)
    assert_equal [ "Secret owner book" ], subscription.items.pluck(:title)
    assert_equal [ [ "ShelfarrList", "Bearer owner_token" ], [ "ShelfarrListBooks", "Bearer owner_token" ] ],
      hardcover_requests.map { |request| request.values_at(:operation, :authorization) }

    viewer = users(:two)
    sign_in_as(viewer)
    hardcover_requests.clear
    post hardcover_subscriptions_path, params: { kind: "list", hardcover_target_id: 77 }
    assert_match(/could not find that list, or it is private/, flash[:alert])
    assert_equal [ [ "ShelfarrPublicList", "Bearer owner_token" ] ], hardcover_requests.map { |request| request.values_at(:operation, :authorization) },
      "without a connection only public lists can be followed, even when the instance token owns the list"

    create_hardcover_connection(viewer, hardcover_user_id: 2_002, access_token: "viewer_token")
    post hardcover_subscriptions_path, params: { kind: "list", hardcover_target_id: 77 }
    assert_match(/could not find that list, or it is private/, flash[:alert])
    assert_equal 0, viewer.hardcover_subscriptions.count
  end

  test "someone else's non-public list is refused even if Hardcover returns it" do
    create_hardcover_connection(@user, hardcover_user_id: 2_002, access_token: "viewer_token")
    stub_hardcover_graphql("ShelfarrList" => { "lists" => [ PRIVATE_LIST.merge("id" => 77, "privacy_setting_id" => 2, "public" => false) ] })

    post hardcover_subscriptions_path, params: { kind: "list", hardcover_target_id: 77 }

    assert_match(/or it is private/, flash[:alert])
    assert_equal 0, @user.hardcover_subscriptions.count
  end

  test "a personal subscription cannot be resumed with a different account" do
    create_hardcover_connection(@user, hardcover_user_id: 5_555)
    subscription = create_hardcover_subscription(@user, kind: "list", account_id: 1_001, personal: true)
    subscription.pause!(HardcoverSubscription::PAUSE_OTHER_ACCOUNT)

    post resume_hardcover_subscription_path(subscription)

    assert subscription.reload.paused?
    assert_match(/different Hardcover account/, flash[:alert])
  end

  # Previews a list or Want to Read shelf holding a released book and one
  # announced for later, then confirms it with automatic requests on.
  def preview_and_confirm(kind, item_selection: [])
    released = hardcover_book(id: 701, title: "Already Out", release_date: "2020-01-01")
    announced = hardcover_book(id: 702, title: "Coming Later", release_date: 3.days.from_now.to_date.iso8601)
    if kind == "want_to_read"
      create_hardcover_connection(@user)
      stub_hardcover_graphql("ShelfarrWantToRead" => { "user_books" => [
        hardcover_user_book_row(released, id: 1, created_at: 1.year.ago.iso8601),
        hardcover_user_book_row(announced, id: 2, created_at: 1.month.ago.iso8601)
      ] }, "ShelfarrWantToReadSince" => { "user_books" => [] })
    else
      stub_hardcover_graphql(
        "ShelfarrPublicList" => { "lists" => [ { "id" => 77, "name" => "Picks", "books_count" => 2, "privacy_setting_id" => 1, "public" => true, "user_id" => 31 } ] },
        "ShelfarrPublicListBooks" => { "list_books" => [ hardcover_list_book_row(released, id: 1), hardcover_list_book_row(announced, id: 2) ] },
        "ShelfarrPublicListBooksSince" => { "list_books" => [] }
      )
    end

    post hardcover_subscriptions_path, params: { kind: kind, hardcover_target_id: (77 if kind == "list") }
    perform_enqueued_jobs(only: HardcoverSubscriptionSyncJob)
    subscription = @user.hardcover_subscriptions.sole
    upcoming = subscription.items.find_by!(hardcover_book_id: 702)
    assert_equal [ "upcoming", true ], [ upcoming.state, upcoming.baseline? ]

    ids = item_selection.map { |book_id| subscription.items.find_by!(hardcover_book_id: book_id).id }
    patch hardcover_subscription_path(subscription), params: { book_types: [ "ebook" ], automatic: "1", item_ids: ids }
    assert subscription.reload.active?
    assert subscription.automatic?
    [ subscription, upcoming ]
  end

  %w[list want_to_read].each do |kind|
    test "an upcoming #{kind} book left unselected in the preview is never requested after release" do
      SettingsService.set(:immediate_search_enabled, false)
      subscription, upcoming = preview_and_confirm(kind)

      travel 4.days do
        assert_no_difference -> { Request.count } do
          HardcoverSyncSchedulerJob.perform_now
          perform_enqueued_jobs(only: HardcoverImportJob)
        end
      end

      assert_equal "known", upcoming.reload.state, "baseline books stay out of automatic requests"
      assert_equal 0, subscription.items.where(state: %w[queued requested]).count
    end

    test "an upcoming #{kind} book selected in the preview is requested after release" do
      SettingsService.set(:immediate_search_enabled, false)
      _subscription, upcoming = preview_and_confirm(kind, item_selection: [ 702 ])
      assert upcoming.reload.wanted?

      travel 4.days do
        assert_difference -> { Request.where(created_via: "hardcover").count } => 1 do
          HardcoverSyncSchedulerJob.perform_now
          perform_enqueued_jobs(only: HardcoverImportJob)
        end
      end

      assert_equal "requested", upcoming.reload.state
    end
  end

  test "a followed author's announced book is requested after release without being selected" do
    SettingsService.set(:immediate_search_enabled, false)
    SettingsService.set(:enabled_languages, [ "en" ])
    stub_hardcover_graphql(
      "ShelfarrAuthor" => { "authors" => [ { "id" => 501, "name" => "Ada Writer", "slug" => "ada" } ] },
      "ShelfarrAuthorRecentContributions" => { "contributions" => [
        hardcover_contribution_row(hardcover_book(id: 801, title: "Announced Novel", release_date: 3.days.from_now.to_date.iso8601), id: 1)
      ] }
    )
    post hardcover_subscriptions_path, params: { kind: "author", hardcover_target_id: 501 }
    perform_enqueued_jobs(only: HardcoverSubscriptionSyncJob)
    subscription = @user.hardcover_subscriptions.sole
    patch hardcover_subscription_path(subscription), params: { book_types: [ "ebook" ], automatic: "1" }
    upcoming = subscription.items.sole
    assert_equal [ "upcoming", true, false ], [ upcoming.state, upcoming.baseline?, upcoming.wanted? ]

    travel 4.days do
      assert_difference -> { Request.where(created_via: "hardcover").count } => 1 do
        HardcoverSyncSchedulerJob.perform_now
        perform_enqueued_jobs(only: HardcoverImportJob)
      end
    end
    assert_equal "requested", upcoming.reload.state
  end

  test "a followed author's book added without a date is requested once Hardcover dates it" do
    SettingsService.set(:immediate_search_enabled, false)
    SettingsService.set(:enabled_languages, [ "en" ])
    catalog = [ hardcover_book(id: 811, title: "Undated At Preview", release_date: nil) ]
    stub_hardcover_graphql(
      "ShelfarrAuthor" => { "authors" => [ { "id" => 501, "name" => "Ada Writer", "slug" => "ada" } ] },
      "ShelfarrAuthorRecentContributions" => ->(_variables) do
        { "contributions" => catalog.each_with_index.map { |book, index| hardcover_contribution_row(book, id: index + 1) } }
      end
    )
    post hardcover_subscriptions_path, params: { kind: "author", hardcover_target_id: 501 }
    perform_enqueued_jobs(only: HardcoverSubscriptionSyncJob)
    subscription = @user.hardcover_subscriptions.sole
    patch hardcover_subscription_path(subscription), params: { book_types: [ "ebook" ], automatic: "1" }

    travel 1.day do
      catalog << hardcover_book(id: 812, title: "Added Later", release_date: nil)
      HardcoverSubscriptionSyncJob.perform_now(subscription.id)
    end
    added = subscription.items.find_by!(hardcover_book_id: 812)
    assert_equal [ "known", false ], [ added.state, added.baseline? ]

    travel 2.days do
      catalog.each { |book| book.merge!("release_date" => Date.current.iso8601, "release_year" => Date.current.year) }
      HardcoverSubscriptionSyncJob.perform_now(subscription.id)
      assert_difference -> { Request.where(created_via: "hardcover").count } => 1 do
        HardcoverSyncSchedulerJob.perform_now
        perform_enqueued_jobs(only: HardcoverImportJob)
      end
    end
    assert_equal "requested", added.reload.state
    assert_equal "known", subscription.items.find_by!(hardcover_book_id: 811).state, "the book shown in the preview stays as chosen"
  end
end
