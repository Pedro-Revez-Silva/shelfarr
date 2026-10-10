# frozen_string_literal: true

require "test_helper"

class Hardcover::SubscriptionSyncTest < ActiveSupport::TestCase
  setup do
    SettingsService.set(:hardcover_enabled, true)
    SettingsService.set(:enabled_languages, [ "en" ])
    @user = users(:one)
  end

  test "a Want to Read preview records every entry without requesting anything" do
    create_hardcover_connection(@user)
    subscription = create_hardcover_subscription(@user, kind: "want_to_read", status: "draft")
    subscription.update!(snapshot_state: "loading")
    first_page = 100.times.map { |index| hardcover_user_book_row(hardcover_book(id: 1_000 + index), id: 10_000 + index) }
    second_page = [
      hardcover_user_book_row(hardcover_book(id: 2_000), id: 20_000),
      hardcover_user_book_row(hardcover_book(id: 2_001, release_date: 2.months.from_now.to_date.iso8601), id: 20_001)
    ]
    stub_hardcover_graphql("ShelfarrWantToRead" => ->(variables) { { "user_books" => variables["offset"].zero? ? first_page : second_page } })

    assert_no_difference -> { Request.count } do
      Hardcover::SubscriptionSync.call(subscription, mode: :snapshot)
    end

    subscription.reload
    assert_equal "ready", subscription.snapshot_state
    assert_equal 102, subscription.items.count
    assert_equal 101, subscription.items.known.count
    assert_equal [ 2_001 ], subscription.items.upcoming.pluck(:hardcover_book_id)
    assert_equal 102, subscription.entries_seen_count
    assert_not subscription.entries_truncated
    assert_equal [ 0, 100 ], hardcover_requests.map { |request| request[:variables]["offset"] }
    assert_equal [ 4242 ], hardcover_requests.map { |request| request[:variables]["userId"] }.uniq
    assert hardcover_requests.all? { |request| request[:authorization] == "Bearer hc_at_test_#{@user.id}" }
    assert_nil subscription.baseline_established_at, "a preview never establishes a baseline by itself"
  end

  test "an automatic list sync queues only entries added after the baseline" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list", target_id: 77, automatic: true, book_types: %w[ebook audiobook], baseline: 2.days.ago)
    create_hardcover_item(subscription, book_id: 3, state: "known")
    rows = [
      hardcover_list_book_row(hardcover_book(id: 1), id: 501, date_added: 1.day.ago.iso8601),
      hardcover_list_book_row(hardcover_book(id: 2), id: 502, date_added: 10.days.ago.iso8601, updated_at: 1.hour.ago.iso8601),
      hardcover_list_book_row(hardcover_book(id: 3, title: "Renamed"), id: 503, date_added: 20.days.ago.iso8601, updated_at: 1.hour.ago.iso8601)
    ]
    stub_hardcover_graphql("ShelfarrListBooksSince" => { "list_books" => rows })

    result = Hardcover::SubscriptionSync.call(subscription)

    assert_equal 1, result.queued
    items = subscription.items.index_by(&:hardcover_book_id)
    assert_equal "queued", items[1].state
    assert_equal %w[ebook audiobook], items[1].book_types
    assert_not items[1].wanted?, "automatic additions are distinguished from explicit selections"
    assert_equal "known", items[2].state, "entries that existed before the baseline are never requested automatically"
    assert_equal "known", items[3].state
    assert_equal "Renamed", items[3].title
    since = Time.zone.parse(hardcover_requests.last[:variables]["since"])
    assert_in_delta subscription.reload.sync_cursor_at, Time.current, 5
    assert_in_delta 2.days.ago - 1.hour, since, 5
    assert_equal 0, Request.where(created_via: "hardcover").count, "the sync only queues; the import job creates requests"
  end

  test "new additions wait for review when automatic requests are off" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list", automatic: false)
    stub_hardcover_graphql("ShelfarrListBooksSince" => { "list_books" => [ hardcover_list_book_row(hardcover_book(id: 9), id: 1, date_added: 1.hour.ago.iso8601) ] })

    Hardcover::SubscriptionSync.call(subscription)

    assert_equal "pending", subscription.items.find_by!(hardcover_book_id: 9).state
  end

  test "an author sync separates new releases, backlist, upcoming books, and other contributors' work" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "author", target_id: 501, automatic: true, baseline: 10.days.ago)
    moved = create_hardcover_item(subscription, book_id: 40, state: "upcoming", release_date: 1.month.from_now.to_date)
    stub_hardcover_graphql("ShelfarrAuthorContributions" => { "contributions" => [
      hardcover_contribution_row(hardcover_book(id: 10, release_date: 3.days.ago.to_date.iso8601), id: 1),
      hardcover_contribution_row(hardcover_book(id: 11, release_date: "2009-05-01"), id: 2),
      hardcover_contribution_row(hardcover_book(id: 12, release_date: 3.months.from_now.to_date.iso8601), id: 3),
      hardcover_contribution_row(hardcover_book(id: 13), id: 4, contribution: "Translator"),
      hardcover_contribution_row(hardcover_book(id: 14), id: 5, contribution: "Editor"),
      hardcover_contribution_row(hardcover_book(id: 40, release_date: 2.months.from_now.to_date.iso8601), id: 6)
    ] })

    Hardcover::SubscriptionSync.call(subscription)

    states = subscription.items.pluck(:hardcover_book_id, :state).to_h
    assert_equal "queued", states[10]
    assert_equal "known", states[11], "an old book added to Hardcover later is backlist, not a new release"
    assert_equal "upcoming", states[12]
    assert_nil states[13]
    assert_nil states[14]
    assert_equal 2.months.from_now.to_date, moved.reload.release_date
    assert_equal({ "role" => 2 }, subscription.reload.exclusions)
  end

  test "a failed page leaves items and the cursor untouched" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list", automatic: true, baseline: 2.days.ago)
    cursor = subscription.sync_cursor_at
    full_page = 100.times.map { |index| hardcover_list_book_row(hardcover_book(id: 100 + index), id: index, date_added: 1.hour.ago.iso8601) }
    stub_hardcover_graphql("ShelfarrListBooksSince" => ->(variables) { variables["offset"].zero? ? { "list_books" => full_page } : [ 503, { error: "Service temporarily unavailable" } ] })

    assert_raises(HardcoverClient::TransientError) { Hardcover::SubscriptionSync.call(subscription) }

    assert_equal 0, subscription.items.count
    assert_equal cursor.to_i, subscription.reload.sync_cursor_at.to_i
  end

  test "an empty response is not treated as removals" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list")
    item = create_hardcover_item(subscription, book_id: 5, state: "requested")
    stub_hardcover_graphql("ShelfarrListBooksSince" => { "list_books" => [] })

    Hardcover::SubscriptionSync.call(subscription)

    assert_equal "requested", item.reload.state
    assert_equal 1, subscription.items.count
  end

  test "a list followed by a connected user is read with their own token" do
    configure_hardcover_instance_token
    create_hardcover_connection(@user)
    subscription = create_hardcover_subscription(@user, kind: "list")
    stub_hardcover_graphql("ShelfarrListBooksSince" => { "list_books" => [] })

    Hardcover::SubscriptionSync.call(subscription)

    assert_equal "Bearer hc_at_test_#{@user.id}", hardcover_requests.last[:authorization]
  end

  test "a very long list preview is bounded and flagged" do
    configure_hardcover_instance_token
    subscription = create_hardcover_subscription(@user, kind: "list", status: "draft")
    stub_hardcover_graphql("ShelfarrListBooks" => ->(variables) do
      offset = variables["offset"]
      { "list_books" => 100.times.map { |index| hardcover_list_book_row(hardcover_book(id: offset + index + 1), id: offset + index + 1) } }
    end)

    Hardcover::SubscriptionSync.call(subscription, mode: :snapshot)

    assert_equal Hardcover::SubscriptionSync::MAX_SNAPSHOT_PAGES, hardcover_requests.size
    assert subscription.reload.entries_truncated
    assert_equal 1_000, subscription.items.count
  end
end
