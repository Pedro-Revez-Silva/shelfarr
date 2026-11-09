# frozen_string_literal: true

require "test_helper"
require_relative "../test_helpers/kobo_test_helper"

class KoboDevicesControllerTest < ActionDispatch::IntegrationTest
  include KoboTestHelper

  setup do
    prepare_kobo_book
    sign_in_as(users(:one))
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test "profile and ebook details expose device setup and personal selection" do
    get profile_path
    assert_select "a[href=?]", kobo_devices_path, text: "Kobo readers"
    get library_path(@book)
    assert_select "button", text: "Send to My Kobo"
    assert_select "form[action=?]", send_book_kobo_device_path(@device)
    get kobo_devices_path
    assert_response :success
    assert_select "body", text: /keep its own Kobo Store library/
  end

  test "new connection address is shown once with no-store and no secret in flash or subsequent pages" do
    post kobo_devices_path, params: { kobo_device: { name: "Clara", base_url: "https://reader.example/shelfarr/" } }
    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    token = response.body.match(%r{https://reader.example/shelfarr/kobo/([a-f0-9]{64})})[1]
    device = KoboDevice.authenticate(token)
    assert_equal "Clara", device.name
    assert_equal "https://reader.example/shelfarr", device.base_url
    assert_not_includes device.attributes.values, token
    assert_not_includes flash.to_h.to_s, token
    get kobo_device_path(device)
    assert_response :success
    assert_not_includes response.body, token
    get kobo_devices_path
    assert_not_includes response.body, token
  end

  test "invalid and unsafe connection addresses stay on form without creating a device" do
    [ "file:///etc/passwd", "https://user:pass@example.com", "https://example.com?private=yes", "https://example.com#fragment", "broken" ].each do |base_url|
      assert_no_difference "KoboDevice.count" do
        post kobo_devices_path, params: { kobo_device: { name: "Reader", base_url: base_url } }
      end
      assert_response :unprocessable_entity
      assert_select "[role=alert]"
    end
    post kobo_devices_path, params: { kobo_device: { name: "", base_url: "http://shelfarr.local:3000" } }
    assert_response :unprocessable_entity
  end

  test "send and resend keep the canonical library copy and do not acquire again" do
    assert_no_difference [ "Book.count", "Request.count" ] do
      assert_difference "KoboDelivery.count", 1 do
        post send_book_kobo_device_path(@device), params: { book_id: @book.id }
      end
    end
    assert_redirected_to library_path(@book)
    assert_match(/Sync your Kobo/, flash[:notice])
    id = @device.kobo_deliveries.sole.entitlement_id
    post send_book_kobo_device_path(@device), params: { book_id: @book.id }
    assert_equal id, @device.kobo_deliveries.sole.entitlement_id
    assert_equal 2, @device.reload.sync_revision
    assert File.file?(@path)
    get kobo_device_path(@device)
    assert_select "body", text: /Queued · waiting for download/
  end

  test "unavailable books return a useful message without adding delivery" do
    File.unlink(@path)
    assert_no_difference "KoboDelivery.count" do
      post send_book_kobo_device_path(@device), params: { book_id: @book.id }
    end
    assert_redirected_to library_path(@book)
    assert_match(/missing|outside/, flash[:alert])
  end

  test "only the owning user may manage rotate send or revoke a reader" do
    other, = KoboDevice.issue(user: users(:two), name: "Someone else's reader", base_url: @device.base_url)
    other.save!
    get kobo_devices_path
    assert_not_includes response.body, "Someone else's reader"
    get kobo_device_path(other)
    assert_response :not_found
    post rotate_kobo_device_path(other)
    assert_response :not_found
    post send_book_kobo_device_path(other), params: { book_id: @book.id }
    assert_response :not_found
    delete kobo_device_path(other)
    assert_response :not_found
    patch kobo_device_path(other), params: { kobo_device: { store_coexistence: true } }
    assert_response :not_found
    post use_kobo_place_kobo_device_path(other), params: { entitlement_id: "x" }
    assert_response :not_found
    assert KoboDevice.exists?(other.id)
    assert_not other.reload.store_coexistence?
  end

  test "regeneration invalidates old address but keeps selection and revoke removes access" do
    @device.send_book!(@book)
    post rotate_kobo_device_path(@device)
    assert_response :success
    assert_nil KoboDevice.authenticate(@token)
    assert_equal 1, @device.kobo_deliveries.count
    assert_difference "KoboDelivery.count", -1 do
      delete kobo_device_path(@device)
    end
    assert_redirected_to kobo_devices_path
    assert File.file?(@path)
  end

  test "device management requires a signed-in user" do
    sign_out
    get kobo_devices_path
    assert_response :redirect
    post kobo_devices_path, params: { kobo_device: { name: "Reader", base_url: @device.base_url } }
    assert_response :redirect
  end

  test "the connect form defaults to keeping the Store over HTTPS and explains both modes" do
    get kobo_devices_path, headers: { "X-Forwarded-Proto" => "https" }
    assert_select "input[type=radio][name='kobo_device[store_coexistence]'][value=true][checked]"
    assert_select "input[type=checkbox][name='kobo_device[share_progress]'][checked]"
    post kobo_devices_path, params: { kobo_device: { name: "Libra", base_url: "https://reader.example/shelfarr", store_coexistence: "true", share_progress: "1" } }
    assert_response :success
    assert_select "[data-testid=kobo-mode]", text: /Kobo Store \+ Shelfarr/
    assert_select "[data-testid=kobo-store-endpoint]", text: "api_endpoint=https://storeapi.kobo.com"
    device = users(:one).kobo_devices.find_by!(name: "Libra")
    assert device.store_coexistence?
    assert device.share_progress?
  end

  test "keeping the Store needs HTTPS because the reader's own sign-in passes through" do
    assert_no_difference "KoboDevice.count" do
      post kobo_devices_path, params: { kobo_device: { name: "Plain", base_url: "http://shelfarr.local:3000", store_coexistence: "true" } }
    end
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /HTTPS/
    @device.update!(base_url: "http://shelfarr.local")
    patch kobo_device_path(@device), params: { kobo_device: { store_coexistence: "true" } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /HTTPS/
    assert_not @device.reload.store_coexistence?
  end

  test "changing the mode keeps the address, selections and reading places, and says what happens next" do
    @device.send_book!(@book)
    digest = @device.token_digest
    patch kobo_device_path(@device), params: { kobo_device: { store_coexistence: "true", share_progress: "1" } }
    assert_redirected_to kobo_device_path(@device)
    assert_match(/Store library and Shelfarr books both arrive/, flash[:notice])
    assert_equal digest, @device.reload.token_digest
    assert_equal 1, @device.kobo_deliveries.count
    patch kobo_device_path(@device), params: { kobo_device: { store_coexistence: "false", base_url: "https://evil.example", name: "Renamed" } }
    assert_match(/Shelfarr books only/, flash[:notice])
    assert_equal [ "https://shelfarr.example", "My Kobo" ], @device.reload.values_at(:base_url, :name)
  end

  test "an unapplied Kobo place is explained and can be chosen explicitly" do
    @device.update!(share_progress: true, store_coexistence: true, store_status: "unavailable", store_checked_at: 1.minute.ago)
    delivery = @device.send_book!(@book)
    asset = Consumer::LibraryAssets.new(@book).list.sole.id
    Consumer::ProgressWriter.new(user: users(:one), book: @book).call("asset_id" => asset, "expected_version" => 0,
      "client_mutation_id" => SecureRandom.uuid, "observed_at" => 1.minute.ago.utc.iso8601(3), "locator" => { "href" => "a.xhtml", "locations" => { "totalProgression" => 0.8 } })
    delivery.update_columns(progress_bridge: { "status" => "superseded", "percent" => 35.0, "observed_at" => 2.hours.ago.utc.iso8601(3),
      "asset_id" => asset, "locator" => { "href" => "b.xhtml", "type" => "application/xhtml+xml", "locations" => { "totalProgression" => 0.35 } } })
    get kobo_device_path(@device)
    assert_select "[data-testid=kobo-store-status]", text: /couldn't be reached.*Shelfarr books still synced/
    assert_select "[data-testid=kobo-place]", text: /Kept a newer place from another device \(80%, read 1 minute ago\). Kobo place: 35%, read about 2 hours ago/
    assert_select "button", text: "Use Kobo place"
    post use_kobo_place_kobo_device_path(@device), params: { entitlement_id: delivery.entitlement_id }
    assert_redirected_to kobo_device_path(@device)
    assert_equal "b.xhtml", users(:one).consumer_progresses.find_by!(book: @book).locator["href"]
    follow_redirect!
    assert_select "[data-testid=kobo-place]", text: /the Kobo place you chose \(35%/
    assert_select "button", text: "Use Kobo place", count: 0
    post use_kobo_place_kobo_device_path(@device), params: { entitlement_id: delivery.entitlement_id }
    assert_match(/no unapplied Kobo place/, flash[:alert])

    delivery.update_columns(progress_bridge: delivery.progress_bridge.merge("status" => "superseded"))
    File.rename(@path, "#{@path}.old")
    write_epub(@path)
    post use_kobo_place_kobo_device_path(@device), params: { entitlement_id: delivery.entitlement_id }
    assert_match(/belongs to an edition/, flash[:alert])
    assert_equal "b.xhtml", users(:one).consumer_progresses.find_by!(book: @book).locator["href"]
  end

  test "receiving Shelfarr places is off for new and existing readers until the owner turns it on" do
    assert_not @device.receive_progress?
    get kobo_devices_path
    assert_select "input[type=checkbox][name='kobo_device[receive_progress]']:not([checked])"
    assert_select "#kobo-receive-help", text: /next Wi-Fi sync.*Only KEPUB files.*Plain EPUB files, books shared from Kobo accounts and Kobo Store books keep their Kobo place.*Not yet tested on a physical Kobo/
    post kobo_devices_path, params: { kobo_device: { name: "Fresh", base_url: "https://shelfarr.example" } }
    assert_not users(:one).kobo_devices.find_by!(name: "Fresh").receive_progress?

    patch kobo_device_path(@device), params: { kobo_device: { receive_progress: "1" } }
    assert_redirected_to kobo_device_path(@device)
    assert_match(/receives Shelfarr reading places for KEPUB books at its next Wi-Fi sync/, flash[:notice])
    assert @device.reload.receive_progress?
    assert_not @device.share_progress?, "the two directions are independent"
    patch kobo_device_path(@device), params: { kobo_device: { receive_progress: "0" } }
    assert_match(/no longer receives Shelfarr reading places/, flash[:notice])

    other, = KoboDevice.issue(user: users(:two), name: "Theirs", base_url: "https://shelfarr.example")
    other.save!
    patch kobo_device_path(other), params: { kobo_device: { receive_progress: "1" } }
    assert_response :not_found
    assert_not other.reload.receive_progress?
  end

  test "a Shelfarr place that needs a choice is explained and can be sent explicitly" do
    prepare_kobo_kepub
    @device.update!(receive_progress: true)
    delivery = @device.send_book!(@book)
    delivery.update!(last_download_at: 1.hour.ago)
    asset = Consumer::LibraryAssets.new(@book).list.sole.id
    Consumer::ProgressWriter.new(user: users(:one), book: @book).call("asset_id" => asset, "expected_version" => 0,
      "client_mutation_id" => SecureRandom.uuid, "locator" => { "href" => "OEBPS/Text/ch2.xhtml", "locations" => { "progression" => 0.5, "totalProgression" => 0.4 } })
    Kobo::OutboundProgress.refresh(@device)
    get kobo_device_path(@device)
    assert_select "[data-testid=kobo-outbound]", text: /Shelfarr's place \(chapter 2 of 3, 40% of the book\) has no reading time/
    assert_select "button", text: "Send Shelfarr place"

    other, = KoboDevice.issue(user: users(:two), name: "Theirs", base_url: "https://shelfarr.example")
    other.save!
    post send_shelfarr_place_kobo_device_path(other), params: { entitlement_id: delivery.entitlement_id }
    assert_response :not_found
    assert_equal "needs_choice", delivery.reload.progress_outbound["status"]

    post send_shelfarr_place_kobo_device_path(@device), params: { entitlement_id: delivery.entitlement_id }
    assert_redirected_to kobo_device_path(@device)
    assert_match(/moves A Library Book to the Shelfarr place at its next Wi-Fi sync/, flash[:notice])
    follow_redirect!
    assert_select "[data-testid=kobo-outbound]", text: /Your chosen Shelfarr place \(chapter 2 of 3, 40% of the book\) waits for this Kobo's next Wi-Fi sync/
    assert_select "button", text: "Send Shelfarr place", count: 0
    post send_shelfarr_place_kobo_device_path(@device), params: { entitlement_id: delivery.entitlement_id }
    assert_match(/no Shelfarr place waiting for a choice/, flash[:alert])
    assert_nil users(:one).consumer_progresses.sole.observed_at, "choosing never invents a Shelfarr reading time"
  end
end
