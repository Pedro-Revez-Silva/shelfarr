# frozen_string_literal: true

require "test_helper"

class Integrations::TelegramWebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    SettingsService.set(:telegram_enabled, true)
    SettingsService.set(:telegram_bot_token, "telegram-token")
    SettingsService.set(:telegram_bot_username, "ShelfarrBot")
    SettingsService.set(:telegram_webhook_secret, "telegram-secret")
    SettingsService.set(:telegram_allowed_chat_ids, "-100123")
    SettingsService.set(:telegram_user_mappings, "42=userone")
  end

  test "rejects webhook requests with invalid secret" do
    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "wrong" },
      params: telegram_update("/whoami"),
      as: :json

    assert_response :unauthorized
  end

  test "responds to commands for linked users in allowed chats" do
    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("/whoami"),
      as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "sendMessage", body["method"]
    assert_equal "Linked as userone.", body["text"]
  end

  test "refuses commands from chats that are not allow-listed" do
    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("/whoami", chat_id: "-100999"),
      as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "This chat is not allowed to use Shelfarr.", body["text"]
  end

  test "creates requests through Telegram command" do
    details = MetadataService::SearchResult.new(
      source: "openlibrary",
      source_id: "OL_TELEGRAM_REQUEST_123W",
      title: "Telegram Request Book",
      author: "Telegram Author",
      description: nil,
      year: 2024,
      cover_url: nil,
      has_audiobook: nil,
      has_ebook: nil,
      series_name: nil,
      series_position: nil
    )

    MetadataService.stub(:book_details, details) do
      assert_difference "Request.count", 1 do
        post integrations_telegram_webhook_path,
          headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
          params: telegram_update("/request openlibrary:OL_TELEGRAM_REQUEST_123W ebook"),
          as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_includes body["text"], "Request created"
    assert_includes body["text"], "Telegram Request Book"
  end

  private

  def telegram_update(text, chat_id: "-100123", sender_id: 42)
    {
      update_id: 123,
      message: {
        message_id: 456,
        text: text,
        chat: {
          id: chat_id,
          type: "supergroup"
        },
        from: {
          id: sender_id,
          username: "telegramuser"
        }
      }
    }
  end
end
