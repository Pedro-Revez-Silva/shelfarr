# frozen_string_literal: true

require "test_helper"

class HardcoverSubscriptionTest < ActiveSupport::TestCase
  test "one subscription per user and target" do
    create_hardcover_subscription(users(:one), kind: "list", target_id: 5)

    duplicate = users(:one).hardcover_subscriptions.build(kind: "list", hardcover_target_id: 5, title: "Again", book_types: [ "ebook" ], status: "active")
    assert_not duplicate.valid?
    assert users(:two).hardcover_subscriptions.build(kind: "list", hardcover_target_id: 5, title: "Mine", book_types: [ "ebook" ]).valid?
  end

  test "validates formats and identifiers" do
    subscription = users(:one).hardcover_subscriptions.build(kind: "author", hardcover_target_id: 0, title: "A", status: "active", book_types: [ "comicbook" ])

    assert_not subscription.valid?
    assert subscription.errors[:book_types].any?
    assert subscription.errors[:hardcover_target_id].any?

    confirmed = users(:one).hardcover_subscriptions.build(kind: "want_to_read", title: "Want to Read", status: "active", book_types: [])
    assert_not confirmed.valid?, "a followed subscription needs at least one format"
    assert_equal "want_to_read", confirmed.target_key
  end

  test "sync failures back off exponentially and respect the provider's retry time" do
    subscription = create_hardcover_subscription(users(:one))

    subscription.record_sync_failure!("boom")
    assert_in_delta 15.minutes.from_now, subscription.next_sync_at, 5
    subscription.record_sync_failure!("boom")
    assert_in_delta 30.minutes.from_now, subscription.next_sync_at, 5
    subscription.record_sync_failure!("rate limited", retry_at: 6.hours.from_now)
    assert_in_delta 6.hours.from_now, subscription.next_sync_at, 5
    10.times { subscription.record_sync_failure!("boom") }
    assert_operator subscription.next_sync_at, :<=, 1.day.from_now + 5
  end

  test "sync interval follows the admin setting within bounds" do
    subscription = create_hardcover_subscription(users(:one))

    SettingsService.set(:hardcover_sync_interval_hours, 0)
    assert_equal 1.hour, subscription.sync_interval
    SettingsService.set(:hardcover_sync_interval_hours, 12)
    assert_equal 12.hours, subscription.sync_interval
  end

  test "Hardcover links for each kind" do
    user = users(:one)
    assert_equal "https://hardcover.app/authors/ada", create_hardcover_subscription(user, kind: "author", target_id: 1).tap { |s| s.update!(slug: "ada") }.hardcover_url
    list = create_hardcover_subscription(user, kind: "list", target_id: 2)
    list.update!(slug: "picks", owner_username: "reader")
    assert_equal "https://hardcover.app/@reader/lists/picks", list.hardcover_url
  end
end
