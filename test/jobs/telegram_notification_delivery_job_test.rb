# frozen_string_literal: true

require "test_helper"

class TelegramNotificationDeliveryJobTest < ActiveJob::TestCase
  setup do
    @request = requests(:pending_request)
    @request.user.update!(telegram_user_id: "42")
    SettingsService.set(:telegram_enabled, true)
    SettingsService.set(:telegram_bot_token, "telegram-token")
    SettingsService.set(:telegram_webhook_secret, "telegram-secret")
    SettingsService.set(:telegram_notification_events, "request_completed")
  end

  test "delivers lifecycle notification to linked telegram user" do
    VCR.turned_off do
      stub = stub_request(:post, "https://api.telegram.org/bottelegram-token/sendMessage")
        .with do |request|
          body = JSON.parse(request.body)
          body["chat_id"] == "42" &&
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

  test "skips unsubscribed events" do
    VCR.turned_off do
      stub = stub_request(:post, "https://api.telegram.org/bottelegram-token/sendMessage")

      TelegramNotificationDeliveryJob.perform_now(event: "request_failed", request_id: @request.id)

      assert_not_requested stub
    end
  end
end
