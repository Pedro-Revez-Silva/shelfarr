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

  test "deliver! includes topic in payload when configured" do
    SettingsService.set(:webhook_topic, "shelfarr")

    stub = stub_request(:post, "http://localhost:4567/webhook")
      .with do |request|
        json = JSON.parse(request.body)
        json["topic"] == "shelfarr" &&
          json["event"] == "request_completed"
      end
      .to_return(status: 200, body: "{\"ok\":true}", headers: { "Content-Type" => "application/json" })

    OutboundNotifications::WebhookDelivery.deliver!(
      event: "request_completed",
      title: "Book Ready",
      message: "test",
      request: @request
    )

    assert_requested(stub)
  end

  test "test_payload includes topic when configured" do
    SettingsService.set(:webhook_topic, "shelfarr")

    payload = OutboundNotifications::WebhookDelivery.test_payload

    assert_equal "shelfarr", payload[:topic]
  end

  test "test_payload omits topic when not configured" do
    payload = OutboundNotifications::WebhookDelivery.test_payload

    assert_not payload.key?(:topic)
  end

  test "deliver! omits topic from payload when not configured" do
    stub = stub_request(:post, "http://localhost:4567/webhook")
      .with do |request|
        json = JSON.parse(request.body)
        !json.key?("topic")
      end
      .to_return(status: 200, body: "{\"ok\":true}", headers: { "Content-Type" => "application/json" })

    OutboundNotifications::WebhookDelivery.deliver!(
      event: "request_completed",
      title: "Book Ready",
      message: "test",
      request: @request
    )

    assert_requested(stub)
  end

  test "deliver! includes the book's absolute cover URL" do
    @request.book.update!(cover_url: "https://covers.openlibrary.org/b/id/12345-L.jpg")

    payload = deliver_payload

    assert_equal "https://covers.openlibrary.org/b/id/12345-L.jpg", payload.dig("book", "cover_url")
  end

  test "deliver! keeps an absolute http cover URL unchanged" do
    @request.book.update!(cover_url: "  http://books.google.com/books/content?id=abc&printsec=frontcover  ")

    payload = deliver_payload

    assert_equal "http://books.google.com/books/content?id=abc&printsec=frontcover", payload.dig("book", "cover_url")
  end

  test "deliver! turns a protocol-relative cover URL into an absolute https URL" do
    @request.book.update!(cover_url: "//covers.openlibrary.org/b/id/12345-L.jpg")

    payload = deliver_payload

    assert_equal "https://covers.openlibrary.org/b/id/12345-L.jpg", payload.dig("book", "cover_url")
  end

  test "deliver! sends null cover_url when the book has no fetchable cover" do
    [ nil, "", "   ", "/images/cover.jpg", "javascript:alert(1)", "https://covers.example.test/a b.jpg" ].each do |cover_url|
      @request.book.update!(cover_url: cover_url)

      payload = deliver_payload

      assert payload["book"].key?("cover_url"), "expected cover_url for #{cover_url.inspect}"
      assert_nil payload.dig("book", "cover_url"), "expected null cover_url for #{cover_url.inspect}"
    end
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

  private

  def deliver_payload
    payload = nil
    stub_request(:post, "http://localhost:4567/webhook").with do |request|
      payload = JSON.parse(request.body)
      true
    end.to_return(status: 200, body: "{\"ok\":true}", headers: { "Content-Type" => "application/json" })

    OutboundNotifications::WebhookDelivery.deliver!(
      event: "request_completed",
      title: "Book Ready",
      message: "ready",
      request: @request
    )

    payload
  end
end
