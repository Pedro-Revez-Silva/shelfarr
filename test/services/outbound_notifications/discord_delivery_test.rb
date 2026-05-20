# frozen_string_literal: true

require "test_helper"

class OutboundNotifications::DiscordDeliveryTest < ActiveSupport::TestCase
  setup do
    @request = requests(:pending_request)
    SettingsService.set(:discord_enabled, true)
    SettingsService.set(:discord_webhook_url, "https://discord.com/api/webhooks/123/token")
    SettingsService.set(:discord_events, "request_completed,request_attention")
  end

  test "enabled_for? respects subscribed events" do
    assert OutboundNotifications::DiscordDelivery.enabled_for?("request_completed")
    assert_not OutboundNotifications::DiscordDelivery.enabled_for?("request_failed")
  end

  test "deliver! posts Discord webhook payload with embeds and no mentions" do
    stub = stub_request(:post, "https://discord.com/api/webhooks/123/token?wait=true")
      .with do |request|
        json = JSON.parse(request.body)
        embed = json["embeds"].first

        request.headers["Content-Type"].include?("application/json") &&
          json["username"] == "Shelfarr" &&
          json["allowed_mentions"] == { "parse" => [] } &&
          json["content"].include?("Book Ready") &&
          embed["title"] == "Book Ready" &&
          embed["description"].include?(@request.book.title) &&
          embed["fields"].any? { |field| field["name"] == "Book" && field["value"] == @request.book.title } &&
          embed["fields"].any? { |field| field["name"] == "Requested By" && field["value"] == @request.user.username }
      end
      .to_return(status: 200, body: { id: "message-id" }.to_json, headers: { "Content-Type" => "application/json" })

    OutboundNotifications::DiscordDelivery.deliver!(
      event: "request_completed",
      title: "Book Ready",
      message: "\"#{@request.book.title}\" is now available for download.",
      request: @request
    )

    assert_requested(stub)
  end

  test "deliver! preserves existing query parameters and asks Discord to wait" do
    SettingsService.set(:discord_webhook_url, "https://discord.com/api/webhooks/123/token?thread_id=456")

    stub = stub_request(:post, "https://discord.com/api/webhooks/123/token?thread_id=456&wait=true")
      .to_return(status: 204, body: "")

    OutboundNotifications::DiscordDelivery.deliver!(
      event: "request_completed",
      title: "Book Ready",
      message: "test",
      request: @request
    )

    assert_requested(stub)
  end

  test "deliver! raises on non-successful response" do
    stub_request(:post, "https://discord.com/api/webhooks/123/token?wait=true")
      .to_return(status: 400, body: { message: "Cannot send an empty message" }.to_json, headers: { "Content-Type" => "application/json" })

    error = assert_raises(OutboundNotifications::DiscordDelivery::DeliveryError) do
      OutboundNotifications::DiscordDelivery.deliver!(
        event: "request_completed",
        title: "Book Ready",
        message: "failed",
        request: @request
      )
    end

    assert_includes error.message, "HTTP 400"
    assert_includes error.message, "Cannot send an empty message"
  end

  test "deliver! reports Discord rate limits" do
    stub_request(:post, "https://discord.com/api/webhooks/123/token?wait=true")
      .to_return(status: 429, body: { message: "You are being rate limited.", retry_after: 1.5 }.to_json, headers: { "Content-Type" => "application/json" })

    error = assert_raises(OutboundNotifications::DiscordDelivery::DeliveryError) do
      OutboundNotifications::DiscordDelivery.deliver!(
        event: "request_completed",
        title: "Book Ready",
        message: "failed",
        request: @request
      )
    end

    assert_includes error.message, "rate limited"
    assert_includes error.message, "1.5"
  end

  test "test_payload includes Discord webhook requirements" do
    payload = OutboundNotifications::DiscordDelivery.test_payload

    assert_equal "Shelfarr", payload[:username]
    assert_equal({ parse: [] }, payload[:allowed_mentions])
    assert payload[:content].present?
    assert_equal "Shelfarr Test", payload[:embeds].first[:title]
  end

  test "deliver! raises a delivery error for invalid webhook URLs" do
    SettingsService.set(:discord_webhook_url, "ht!tp://bad")

    error = assert_raises(OutboundNotifications::DiscordDelivery::DeliveryError) do
      OutboundNotifications::DiscordDelivery.deliver!(
        event: "request_completed",
        title: "Book Ready",
        message: "failed",
        request: @request
      )
    end

    assert_includes error.message.downcase, "invalid"
  end
end
