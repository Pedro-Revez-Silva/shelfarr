# frozen_string_literal: true

require "test_helper"

class Integrations::TelegramWebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    SettingsService.set(:telegram_enabled, true)
    SettingsService.set(:telegram_bot_token, "telegram-token")
    SettingsService.set(:telegram_bot_username, "ShelfarrBot")
    SettingsService.set(:telegram_webhook_secret, "telegram-secret")
    SettingsService.set(:telegram_allowed_chat_ids, "-100123")
    SettingsService.set(:telegram_user_mappings, "")
    @user = users(:one)
  end

  test "rejects webhook requests with invalid secret" do
    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "wrong" },
      params: telegram_update("/whoami"),
      as: :json

    assert_response :unauthorized
  end

  test "responds to commands for linked users in allowed chats" do
    @user.update!(telegram_user_id: "42")

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
    @user.update!(telegram_user_id: "42")

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

    request = Request.last
    assert_equal "telegram", request.created_via
    assert_equal "telegram", request.external_source
    assert_equal "42", request.external_user_id
    assert_equal "-100123", request.external_chat_id
  end

  test "ignores duplicate telegram updates" do
    @user.update!(telegram_user_id: "42")

    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("/whoami", update_id: 999),
      as: :json

    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("/whoami", update_id: 999),
      as: :json

    assert_response :success
    assert_equal 1, TelegramUpdate.where(update_id: "999").count
    assert_empty response.body
  end

  test "creates requests from inline callback query" do
    @user.update!(telegram_user_id: "42")

    details = MetadataService::SearchResult.new(
      source: "openlibrary",
      source_id: "OL_TELEGRAM_CALLBACK_123W",
      title: "Telegram Callback Book",
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
          params: telegram_callback("request|openlibrary:OL_TELEGRAM_CALLBACK_123W|ebook"),
          as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_includes body["text"], "Request created"
  end

  test "links telegram user with a profile-generated code" do
    code = @user.generate_telegram_link_code!

    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("/link userone #{code}"),
      as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Telegram linked to userone.", body["text"]
    assert_equal "42", @user.reload.telegram_user_id
    assert_equal "telegramuser", @user.telegram_username
    assert_nil @user.telegram_link_token_digest
  end

  test "rejects invalid telegram link code" do
    @user.generate_telegram_link_code!

    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("/link userone 000000"),
      as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Invalid or expired link code.", body["text"]
    assert_nil @user.reload.telegram_user_id
  end

  test "rejects malformed json payload" do
    post integrations_telegram_webhook_path,
      headers: {
        "Content-Type" => "application/json",
        "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret"
      },
      params: "{bad json"

    assert_response :bad_request
  end

  test "ignores non command messages" do
    @user.update!(telegram_user_id: "42")

    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("hello"),
      as: :json

    assert_response :success
    assert_empty response.body
  end

  test "ignores commands addressed to another bot" do
    @user.update!(telegram_user_id: "42")

    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("/whoami@OtherBot"),
      as: :json

    assert_response :success
    assert_empty response.body
  end

  test "uses legacy user mapping fallback" do
    SettingsService.set(:telegram_user_mappings, "42=userone")

    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("/whoami"),
      as: :json

    assert_response :success
    assert_equal "Linked as userone.", JSON.parse(response.body)["text"]
  end

  test "handles callbacks from unlinked users" do
    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_callback("request|openlibrary:OL_UNLINKED_CALLBACK_123W|ebook"),
      as: :json

    assert_response :success
    assert_equal "Your Telegram account is not linked to a Shelfarr user.", JSON.parse(response.body)["text"]
  end

  private

  def telegram_update(text, chat_id: "-100123", sender_id: 42, update_id: 123)
    {
      update_id: update_id,
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

  def telegram_callback(data, chat_id: "-100123", sender_id: 42, update_id: 321)
    {
      update_id: update_id,
      callback_query: {
        id: "callback-1",
        data: data,
        from: {
          id: sender_id,
          username: "telegramuser"
        },
        message: {
          message_id: 456,
          chat: {
            id: chat_id,
            type: "supergroup"
          }
        }
      }
    }
  end
end
