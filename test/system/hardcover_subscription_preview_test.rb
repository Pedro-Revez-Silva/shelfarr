# frozen_string_literal: true

require "application_system_test_case"

class HardcoverSubscriptionPreviewTest < ApplicationSystemTestCase
  test "confirming a preview queues only the selected book and keeps the rest as the baseline" do
    SettingsService.set(:hardcover_enabled, true)
    user = users(:one)
    subscription = create_hardcover_subscription(user, kind: "author", target_id: 501, status: "draft", title: "Ada Writer")
    chosen = create_hardcover_item(subscription, book_id: 11, title: "Chosen Novel")
    skipped = create_hardcover_item(subscription, book_id: 12, title: "Skipped Novel")
    sign_in_as(user)

    visit hardcover_subscription_path(subscription)
    assert_text "Choose what to request"
    check "Chosen Novel"
    assert_text "1 selected on this page"
    check "Audiobook"
    check "Request new releases automatically when they come out"
    click_button "Follow and request selected"

    assert_text "Following Ada Writer. Queued 1 book for request."
    assert_equal [ "queued", %w[audiobook ebook] ], [ chosen.reload.state, chosen.book_types.sort ]
    assert_equal "known", skipped.reload.state
    assert subscription.reload.automatic?
    assert_equal 0, Request.where(created_via: "hardcover").count, "requests are created by the import job"
  end
end
