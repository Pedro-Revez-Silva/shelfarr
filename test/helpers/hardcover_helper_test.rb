# frozen_string_literal: true

require "test_helper"

class HardcoverHelperTest < ActionView::TestCase
  test "format status is tracked separately for each format" do
    Book.create!(title: "T", hardcover_id: "77", book_type: :ebook, file_path: "/ebooks/t.epub")
    audiobook = Book.create!(title: "T", hardcover_id: "77", book_type: :audiobook)
    Request.create!(user: users(:one), book: audiobook)

    statuses = hardcover_format_statuses("hardcover:77", Book.preload_by_work_ids([ "hardcover:77" ]))

    assert_equal({ "audiobook" => :requested, "ebook" => :acquired }, statuses)
    assert_equal({ "audiobook" => :available, "ebook" => :available }, hardcover_format_statuses("hardcover:78", {}))
  end

  test "sync status describes paused, draft, failed, and checked subscriptions" do
    subscription = create_hardcover_subscription(users(:one))
    subscription.update!(last_synced_at: 2.hours.ago)
    assert_match(/Checked about 2 hours ago/, hardcover_sync_status(subscription))

    subscription.update!(last_error: "Hardcover is temporarily unavailable")
    assert_match(/Last check failed/, hardcover_sync_status(subscription))

    subscription.pause!("Paused by you.")
    assert_equal "Paused: Paused by you.", hardcover_sync_status(subscription)
  end
end
