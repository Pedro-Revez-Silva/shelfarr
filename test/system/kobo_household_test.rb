# frozen_string_literal: true

require "application_system_test_case"
require_relative "../test_helpers/kobo_household_test_helper"

# Owner → recipient household sharing through the real browser UI, with
# synthetic accounts, titles and Kobo hosts.
class KoboHouseholdTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include KoboHouseholdTestHelper

  setup do
    setup_kobo_household
    @protected = @account.kobo_account_books.create!(entitlement_id: "protected-entry", title: "A Protected Purchase",
      author: "Another Author", ownership_type: "purchased", rights: "protected", rights_checked_at: Time.current)
    @account.kobo_account_books.create!(entitlement_id: "plus-entry", title: "A Kobo Plus Title", ownership_type: "subscription",
      rights: "drm_free", rights_checked_at: Time.current)
  end

  teardown { teardown_kobo_household }

  test "an owner shares, a recipient prepares and sends to their own reader, and revocation ends access" do
    sign_in_as(@owner)
    visit kobo_account_path(@account)
    within("#sharing") do
      assert_text "Only you can see this catalogue."
      select "Admin User (admin)", from: "Share with"
      click_button "Share catalogue"
    end
    assert_text "Shared with Admin User"
    within("#sharing") { assert_selector "[data-testid=kobo-share]", text: "Admin User" }
    capture("01-owner-sharing-desktop.png")

    sign_in_as(@recipient)
    visit profile_path
    click_link "Shared Kobo books"
    assert_text "Shared by User One"
    click_link "Browse"
    assert_text "A Protected Purchase"
    assert_text "Protected by DRM · can't be sent"
    assert_text "Kobo Plus subscription · can't be shared"
    click_link "Can be sent"
    assert_no_text "A Protected Purchase"
    click_link "A Shared Purchase"
    assert_text "DRM-free EPUB · can be sent"
    assert_text "You haven't connected a Kobo reader to Shelfarr yet."
    assert_no_text "reader@example.test"

    device, = recipient_device
    stub_book_metadata
    stub_book_download
    click_button "Prepare copy"
    assert_text "Preparing a private copy from Kobo"
    perform_enqueued_jobs(only: KoboBookFetchJob)
    using_wait_time(15) { assert_text "Ready · EPUB3 3.0" }
    click_button "Send to #{device.name}"
    assert_text "Queued for #{device.name}"
    assert_text "Queued · waiting for the reader's next sync"
    capture("02-recipient-ready-and-queued-desktop.png")
    assert_equal 1, device.kobo_deliveries.count

    sign_in_as(@owner)
    visit kobo_account_path(@account)
    accept_confirm { click_button "Stop sharing" }
    assert_text "Admin User can no longer see this catalogue"
    assert_equal 0, device.kobo_deliveries.count

    sign_in_as(@recipient)
    visit kobo_account_book_path(@shared_book)
    assert_no_text "A Shared Purchase"
    visit kobo_shared_libraries_path
    assert_text "Nobody has shared a Kobo catalogue with you yet."
  end

  test "recipient pages fit a phone with large text, including protected, failed and stale states" do
    share_with
    device, = recipient_device
    page.current_window.resize_to(390, 844)
    sign_in_as(@recipient)
    visit kobo_shared_library_path(@account)
    enlarge_text
    assert_text "A Protected Purchase"
    assert_no_horizontal_overflow
    capture("03-recipient-catalogue-phone-large-text.png")

    visit kobo_account_book_path(@protected)
    enlarge_text
    assert_text "Shelfarr does not remove DRM"
    assert_no_button "Prepare copy"
    assert_no_horizontal_overflow
    capture("04-protected-edition-phone-large-text.png")

    stub_book_metadata
    stub_book_download(synthetic_epub.byteslice(0, 64), length: 64)
    row = Kobo::BookCache.request!(@shared_book, @recipient)
    Kobo::BookCache.new(row).call
    visit kobo_account_book_path(@shared_book)
    enlarge_text
    assert_text "The download was incomplete"
    assert_button "Try again"
    assert_no_horizontal_overflow
    capture("05-incomplete-download-phone-large-text.png")

    prepare_copy(viewer: @recipient)
    @shared_book.update!(revision_id: "edition-2")
    visit kobo_account_book_path(@shared_book)
    enlarge_text
    assert_text "Kobo now lists a newer edition"
    assert_button "Send to #{device.name}"
    assert_no_horizontal_overflow
    capture("06-stale-edition-phone-large-text.png")
  end

  test "the owner's account page with shares fits a phone with large text" do
    share_with
    page.current_window.resize_to(390, 844)
    sign_in_as(@owner)
    visit kobo_account_path(@account)
    enlarge_text
    assert_text "Household sharing"
    assert_button "Stop sharing"
    assert_no_horizontal_overflow
    capture("07-owner-sharing-phone-large-text.png")
  end

  private

  # Approximates a 200% browser text-size preference: Tailwind sizes use rem.
  def enlarge_text
    page.execute_script("document.documentElement.style.fontSize = '200%'")
  end

  def assert_no_horizontal_overflow
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
      "page is #{page.evaluate_script('document.documentElement.scrollWidth')}px wide"
  end

  def capture(filename)
    return unless ENV["KOBO_SCREENSHOT_DIR"].present?

    FileUtils.mkdir_p(ENV.fetch("KOBO_SCREENSHOT_DIR"))
    page.save_screenshot(File.join(ENV.fetch("KOBO_SCREENSHOT_DIR"), filename))
  end
end
