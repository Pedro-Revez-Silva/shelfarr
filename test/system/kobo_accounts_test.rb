# frozen_string_literal: true

require "application_system_test_case"
require_relative "../test_helpers/kobo_account_test_helper"

class KoboAccountsTest < ApplicationSystemTestCase
  include KoboAccountTestHelper

  setup { sign_in_as(users(:one)) }

  test "approve through the account screen and inspect its private catalogue" do
    stub_kobo_activation
    stub_kobo_approval
    stub_kobo_tokens
    stub_kobo_catalogue
    visit profile_path
    click_link "Kobo accounts"
    fill_in "Connection name", with: "My purchased books"
    click_button "Connect Kobo account"
    assert_selector "h2", text: "Approve this connection on Kobo"
    assert_text "123456"
    assert_link "Open Kobo activation", href: "https://www.kobo.com/activate"
    capture("01-kobo-approval-desktop.png")
    using_wait_time(15) { assert_text "Connected to Kobo" }
    account = users(:one).kobo_accounts.sole
    KoboCatalogSyncJob.perform_now(account.id, account.sync_request_id)
    using_wait_time(15) { assert_text "A Purchased Book" }
    assert_text "Catalogue only"
    assert_no_text "123456"
    capture("02-kobo-catalogue-desktop.png")
  end

  test "approval and long catalogue entries fit a mobile viewport" do
    page.current_window.resize_to(390, 844)
    account = create_kobo_account(next_poll_at: 1.minute.from_now)
    visit kobo_account_path(account)
    assert_text "Approve this connection on Kobo"
    assert_no_horizontal_overflow
    capture("03-kobo-approval-mobile.png")
    account.update!(account.clear_activation.merge(status: "connected", kobo_email: "reader@example.test"))
    account.kobo_account_books.create!(entitlement_id: "book", title: "A very long purchased title " * 8, author: "A very long contributor name " * 8)
    visit kobo_account_path(account)
    assert_text "Connected to Kobo"
    assert_no_horizontal_overflow
    capture("04-kobo-catalogue-mobile.png")
  end

  private

  def assert_no_horizontal_overflow
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
  end

  def capture(filename)
    return unless ENV["KOBO_SCREENSHOT_DIR"].present?

    FileUtils.mkdir_p(ENV.fetch("KOBO_SCREENSHOT_DIR"))
    page.save_screenshot(File.join(ENV.fetch("KOBO_SCREENSHOT_DIR"), filename))
  end
end
