# frozen_string_literal: true

require "test_helper"

class HardcoverSubscriptionItemTest < ActiveSupport::TestCase
  setup { @subscription = create_hardcover_subscription(users(:one)) }

  test "unreleased books are not requestable until release" do
    item = create_hardcover_item(@subscription, book_id: 1, state: "pending", release_date: Date.tomorrow)

    assert_not item.requestable?
    travel 2.days do
      assert item.requestable?
    end
  end

  test "queued and requested items are not requestable again" do
    assert_not create_hardcover_item(@subscription, book_id: 2, state: "queued").requestable?
    assert_not create_hardcover_item(@subscription, book_id: 3, state: "requested").requestable?
    assert create_hardcover_item(@subscription, book_id: 4, state: "failed").requestable?
  end

  test "claimable excludes fresh claims and deferred items" do
    fresh = create_hardcover_item(@subscription, book_id: 5, state: "queued", claimed_at: 1.minute.ago, claim_token: "x")
    stale = create_hardcover_item(@subscription, book_id: 6, state: "queued", claimed_at: 1.hour.ago, claim_token: "y")
    deferred = create_hardcover_item(@subscription, book_id: 7, state: "queued", next_attempt_at: 1.hour.from_now)
    ready = create_hardcover_item(@subscription, book_id: 8, state: "queued")

    assert_equal [ stale.id, ready.id ].sort, HardcoverSubscriptionItem.claimable.pluck(:id).sort
    assert fresh && deferred
  end

  test "metadata for request creation uses the stable Hardcover identity" do
    item = create_hardcover_item(@subscription, book_id: 9, title: "T", release_year: 2001, series_name: "S", series_position: "2")

    assert_equal "hardcover:9", item.work_id
    assert_equal({ title: "T", author: "Ada Writer", first_publish_year: 2001, series: "S", series_position: "2", content_kind: "book" }, item.metadata_attrs)
  end
end
