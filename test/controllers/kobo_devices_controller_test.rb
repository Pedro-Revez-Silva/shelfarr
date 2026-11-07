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
    assert_select "body", text: /Kobo Store sync endpoint/
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
    assert KoboDevice.exists?(other.id)
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
end
