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
    assert_text "keep its own Kobo Store library beside Shelfarr books"
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

  test "keep the Kobo Store on a new reader, then change the mode and see the reader's state" do
    visit kobo_devices_path
    fill_in "Reader name", with: "Libra"
    fill_in "Shelfarr address reachable from this reader", with: "https://shelfarr.example/books"
    choose "Keep my Kobo Store library"
    assert_checked_field "Share reading places with Shelfarr"
    click_button "Create connection"
    assert_text "Mode: Kobo Store + Shelfarr"
    assert_selector "[data-testid=kobo-endpoint]", text: %r{api_endpoint=https://shelfarr.example/books/kobo/[0-9a-f]{64}}
    assert_selector "[data-testid=kobo-store-endpoint]", text: "api_endpoint=https://storeapi.kobo.com"
    # Screenshots never show a connection address, even a test one.
    page.execute_script("document.querySelector('[data-testid=kobo-endpoint]').textContent = 'api_endpoint=https://shelfarr.example/books/kobo/<private-device-token>'")
    capture("kobo-coexistence-setup.png")
    click_link "Done · manage reader"
    assert_text "Kobo Store + Shelfarr"
    assert_selector "[data-testid=kobo-store-status]", text: "Waiting for this reader's first Store sync"
    assert_checked_field "Keep my Kobo Store library"

    choose "Shelfarr books only"
    click_button "Save settings"
    assert_text "Libra now syncs Shelfarr books only"
    assert_text "Shelfarr books only · Waiting for first sync"
    assert_no_selector "[data-testid=kobo-store-status]"
    assert_not users(:one).kobo_devices.find_by!(name: "Libra").store_coexistence?
  end

  test "an HTTP address cannot keep the Store and the reason is shown next to the form" do
    visit kobo_devices_path
    fill_in "Reader name", with: "Plain"
    fill_in "Shelfarr address reachable from this reader", with: "http://shelfarr.local"
    choose "Keep my Kobo Store library"
    click_button "Create connection"
    assert_selector "[role=alert]", text: "must use HTTPS to keep the Kobo Store"
    assert_checked_field "Keep my Kobo Store library"
  end

  test "an older Kobo place is explained and can be chosen explicitly" do
    @device.update!(share_progress: true, store_coexistence: true, store_status: "ok", store_checked_at: 2.minutes.ago)
    delivery = @device.send_book!(@book)
    asset = Consumer::LibraryAssets.new(@book).list.sole.id
    Consumer::ProgressWriter.new(user: users(:one), book: @book).call("asset_id" => asset, "expected_version" => 0,
      "client_mutation_id" => SecureRandom.uuid, "observed_at" => 5.minutes.ago.utc.iso8601(3),
      "locator" => { "href" => "OEBPS/a.xhtml", "locations" => { "totalProgression" => 0.8 } })
    delivery.update_columns(progress_bridge: { "status" => "superseded", "percent" => 35.0, "observed_at" => 3.hours.ago.utc.iso8601(3),
      "asset_id" => asset, "locator" => { "href" => "OEBPS/b.xhtml", "type" => "application/xhtml+xml", "locations" => { "totalProgression" => 0.35 } } })
    visit kobo_device_path(@device)
    assert_selector "[data-testid=kobo-store-status]", text: "Kobo Store answered 2 minutes ago."
    assert_selector "[data-testid=kobo-place]", text: "Kept a newer place from another device (80%, read 5 minutes ago). Kobo place: 35%, read about 3 hours ago."
    capture("kobo-place-choice.png")
    accept_confirm(/Resume A Library Book at the Kobo place/) { click_button "Use Kobo place" }
    assert_text "Shelfarr now resumes A Library Book at the Kobo place."
    assert_selector "[data-testid=kobo-place]", text: "Shelfarr resumes at the Kobo place you chose (35%"
    assert_no_button "Use Kobo place"
    assert_equal "OEBPS/b.xhtml", users(:one).consumer_progresses.find_by!(book: @book).locator["href"]
  end

  test "reader settings and place notices fit a narrow screen" do
    @device.update!(share_progress: true, store_coexistence: true, store_status: "authorization", store_checked_at: 1.minute.ago)
    delivery = @device.send_book!(@book)
    delivery.update_columns(progress_bridge: { "status" => "unsupported", "reason" => "no_location", "percent" => 12.0 })
    page.current_window.resize_to(390, 844)
    visit kobo_device_path(@device)
    assert_selector "[data-testid=kobo-store-status]", text: "Kobo asked this reader to sign in again"
    assert_selector "[data-testid=kobo-place]", text: "Kobo sent only a percentage (12%), not a chapter"
    assert_no_horizontal_overflow
    capture("kobo-reader-settings-mobile.png")
    visit kobo_devices_path
    assert_no_horizontal_overflow
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
