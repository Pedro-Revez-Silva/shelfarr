# frozen_string_literal: true

require "test_helper"

class OutboundWebhookDeliveryJobTest < ActiveJob::TestCase
  setup do
    @request = requests(:pending_request)
    SettingsService.set(:webhook_enabled, true)
    SettingsService.set(:webhook_url, "http://localhost:4567/webhook")
    SettingsService.set(:webhook_events, "request_completed")
  end

  test "delivers subscribed event" do
    stub = stub_request(:post, "http://localhost:4567/webhook")
      .to_return(status: 200, body: "{\"ok\":true}", headers: { "Content-Type" => "application/json" })

    OutboundWebhookDeliveryJob.perform_now(
      event: "request_completed",
      request_id: @request.id,
      title: "Book Ready",
      message: "\"#{@request.book.title}\" is now available for download."
    )

    assert_requested(stub)
  end

  test "skips unsubscribed event" do
    SettingsService.set(:webhook_events, "request_attention")

    OutboundWebhookDeliveryJob.perform_now(
      event: "request_completed",
      request_id: @request.id,
      title: "Book Ready",
      message: "\"#{@request.book.title}\" is now available for download."
    )

    assert_not_requested(:post, "http://localhost:4567/webhook")
  end
end
