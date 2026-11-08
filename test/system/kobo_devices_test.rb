# frozen_string_literal: true

require "application_system_test_case"
require_relative "../test_helpers/kobo_test_helper"

class KoboDevicesTest < ApplicationSystemTestCase
  include KoboTestHelper

  setup do
    prepare_kobo_book
    sign_in_as(users(:one))
  end

  teardown { FileUtils.remove_entry(@root) }

  test "connect a stock reader and send an acquired ebook" do
    visit profile_path
    assert_link "Reader preview", href: consumer_library_path
    click_link "Kobo readers"
    assert_text "Connecting Shelfarr replaces"
    fill_in "Reader name", with: "My older Kobo"
    fill_in "Shelfarr address reachable from this reader", with: "https://shelfarr.example"
    click_button "Create connection"
    assert_text "Connect My older Kobo"
    assert_selector "pre", text: /api_endpoint=https:\/\/shelfarr.example\/kobo\/[0-9a-f]{64}/
    click_link "Done · manage reader"
    assert_text "Waiting for first sync"
    visit library_path(@book)
    assert_link "Open in reader preview", href: consumer_publication_path(@book)
    click_button "Send to My older Kobo"
    assert_text "Queued for My older Kobo"
    assert_equal @book.id, users(:one).kobo_devices.find_by!(name: "My older Kobo").kobo_deliveries.sole.book_id
  end

  test "reader management and selection fit a narrow screen" do
    page.current_window.resize_to(390, 844)
    visit kobo_devices_path
    assert_selector "h1", text: "Kobo readers"
    assert_no_horizontal_overflow
    capture("kobo-readers-mobile.png")
    visit library_path(@book)
    assert_button "Send to My Kobo"
    assert_no_horizontal_overflow
    capture("kobo-send-mobile.png")
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
