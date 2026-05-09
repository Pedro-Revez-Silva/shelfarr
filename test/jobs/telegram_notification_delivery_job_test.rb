# frozen_string_literal: true

require "test_helper"

class TelegramNotificationDeliveryJobTest < ActiveJob::TestCase
  setup do
    @request = requests(:pending_request)
    @request.update!(created_via: "telegram", external_source: "telegram", external_chat_id: "-100123")
    SettingsService.set(:telegram_enabled, true)
    SettingsService.set(:telegram_bot_token, "telegram-token")
    SettingsService.set(:telegram_webhook_secret, "telegram-secret")
    SettingsService.set(:telegram_allowed_chat_ids, "-100123")
    SettingsService.set(:telegram_notification_events, "request_completed")
  end

  test "delivers lifecycle notification to authorized telegram group" do
    VCR.turned_off do
      stub = stub_request(:post, "https://api.telegram.org/bottelegram-token/sendMessage")
        .with do |request|
          body = JSON.parse(request.body)
          body["chat_id"] == "-100123" &&
            body["text"].include?(@request.book.title)
        end
        .to_return(
          status: 200,
          body: { ok: true, result: {} }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      TelegramNotificationDeliveryJob.perform_now(event: "request_completed", request_id: @request.id)

      assert_requested stub
    end
  end

  test "skips telegram requests from unauthorized groups" do
    SettingsService.set(:telegram_allowed_chat_ids, "")

    VCR.turned_off do
      stub = stub_request(:post, "https://api.telegram.org/bottelegram-token/sendMessage")

      TelegramNotificationDeliveryJob.perform_now(event: "request_completed", request_id: @request.id)

      assert_not_requested stub
    end
  end

  test "skips telegram requests from paused groups" do
    TelegramChatAuthorization.create!(
      chat_id: "-100123",
      chat_title: "Paused Group",
      approved_at: Time.current,
      paused_at: Time.current
    )

    VCR.turned_off do
      stub = stub_request(:post, "https://api.telegram.org/bottelegram-token/sendMessage")

      TelegramNotificationDeliveryJob.perform_now(event: "request_completed", request_id: @request.id)

      assert_not_requested stub
    end
  end

  test "skips unsubscribed events" do
    VCR.turned_off do
      stub = stub_request(:post, "https://api.telegram.org/bottelegram-token/sendMessage")

      TelegramNotificationDeliveryJob.perform_now(event: "request_failed", request_id: @request.id)

      assert_not_requested stub
    end
  end
end
