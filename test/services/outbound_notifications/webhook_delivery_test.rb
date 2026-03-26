# frozen_string_literal: true

require "test_helper"

class OutboundNotifications::WebhookDeliveryTest < ActiveSupport::TestCase
  setup do
    @request = requests(:pending_request)
    SettingsService.set(:webhook_enabled, true)
    SettingsService.set(:webhook_url, "http://localhost:4567/webhook")
    SettingsService.set(:webhook_token, "secret-token")
    SettingsService.set(:webhook_events, "request_completed,request_attention")
  end

  test "enabled_for? respects subscribed events" do
    assert OutboundNotifications::WebhookDelivery.enabled_for?("request_completed")
    assert_not OutboundNotifications::WebhookDelivery.enabled_for?("request_failed")
  end

  test "deliver! posts JSON payload with request metadata" do
    stub = stub_request(:post, "http://localhost:4567/webhook")
      .with do |request|
        json = JSON.parse(request.body)
        request.headers["Authorization"] == "Bearer secret-token" &&
          request.headers["X-Shelfarr-Event"] == "request_completed" &&
          json["event"] == "request_completed" &&
          json["request"]["id"] == @request.id &&
          json["book"]["title"] == @request.book.title &&
          json["user"]["username"] == @request.user.username
      end
      .to_return(status: 200, body: "{\"ok\":true}", headers: { "Content-Type" => "application/json" })

    OutboundNotifications::WebhookDelivery.deliver!(
      event: "request_completed",
      title: "Book Ready",
      message: "\"#{@request.book.title}\" is now available for download.",
      request: @request
    )

    assert_requested(stub)
  end

  test "deliver! raises on non-successful response" do
    stub_request(:post, "http://localhost:4567/webhook")
      .to_return(status: 500, body: "boom")

    error = assert_raises(OutboundNotifications::WebhookDelivery::DeliveryError) do
      OutboundNotifications::WebhookDelivery.deliver!(
        event: "request_completed",
        title: "Book Ready",
        message: "failed",
        request: @request
      )
    end

    assert_includes error.message, "HTTP 500"
  end

  test "deliver! raises a delivery error for invalid webhook URLs" do
    SettingsService.set(:webhook_url, "ht!tp://bad")

    error = assert_raises(OutboundNotifications::WebhookDelivery::DeliveryError) do
      OutboundNotifications::WebhookDelivery.deliver!(
        event: "request_completed",
        title: "Book Ready",
        message: "failed",
        request: @request
      )
    end

    assert_includes error.message.downcase, "invalid"
  end
end
