# frozen_string_literal: true

require "application_system_test_case"

class ConsumerConnectionsTest < ApplicationSystemTestCase
  setup do
    @forgery_protection = Consumer::ConnectionsController.allow_forgery_protection
    @origin_check = Consumer::ConnectionsController.forgery_protection_origin_check
    Consumer::ConnectionsController.allow_forgery_protection = true
    Consumer::ConnectionsController.forgery_protection_origin_check = true
    sign_in_as(users(:one))
  end

  teardown do
    Consumer::ConnectionsController.allow_forgery_protection = @forgery_protection
    Consumer::ConnectionsController.forgery_protection_origin_check = @origin_check
  end

  test "approve requesting in the browser with production CSRF checks enabled" do
    token, = APIToken.issue!(name: "Fixture phone", user: users(:one), scopes: ConsumerDeviceGrant::SCOPES,
      issued_via: APIToken::CONSUMER_DEVICE)
    grant, _, code = ConsumerDeviceGrant.issue!(client_name: "Fixture phone",
      scope: (ConsumerDeviceGrant::SCOPES + ConsumerDeviceGrant::REQUEST_SCOPES).join(" "), replaces: token)

    visit consumer_connect_path(user_code: code)
    assert_text "Allow requesting from your app"
    click_button "Allow requesting"
    assert_selector "h1", text: "Requesting allowed"
    assert grant.reload.approved_at
    assert_equal users(:one), grant.user
    assert_not token.reload.revoked?
  end
end
