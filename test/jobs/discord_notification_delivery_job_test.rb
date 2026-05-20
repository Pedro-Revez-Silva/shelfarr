# frozen_string_literal: true

require "test_helper"

class DiscordNotificationDeliveryJobTest < ActiveJob::TestCase
  setup do
    @request = requests(:pending_request)
    SettingsService.set(:discord_enabled, true)
    SettingsService.set(:discord_webhook_url, "https://discord.com/api/webhooks/123/token")
    SettingsService.set(:discord_events, "request_completed")
  end

  test "delivers subscribed event" do
    stub = stub_request(:post, "https://discord.com/api/webhooks/123/token?wait=true")
      .to_return(status: 200, body: { id: "message-id" }.to_json, headers: { "Content-Type" => "application/json" })

    DiscordNotificationDeliveryJob.perform_now(
      event: "request_completed",
      request_id: @request.id,
      title: "Book Ready",
      message: "\"#{@request.book.title}\" is now available for download."
    )

    assert_requested(stub)
  end

  test "skips unsubscribed event" do
    SettingsService.set(:discord_events, "request_attention")

    DiscordNotificationDeliveryJob.perform_now(
      event: "request_completed",
      request_id: @request.id,
      title: "Book Ready",
      message: "\"#{@request.book.title}\" is now available for download."
    )

    assert_not_requested(:post, "https://discord.com/api/webhooks/123/token?wait=true")
  end
end
