# frozen_string_literal: true

require "test_helper"

class Integrations::TelegramWebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    SettingsService.set(:telegram_enabled, true)
    SettingsService.set(:telegram_update_mode, "webhook")
    SettingsService.set(:telegram_bot_token, "telegram-token")
    SettingsService.set(:telegram_bot_username, "ShelfarrBot")
    SettingsService.set(:telegram_webhook_secret, "telegram-secret")
    SettingsService.set(:telegram_allowed_chat_ids, "-100123")
    SettingsService.set(:telegram_request_username, "userone")
    @user = users(:one)
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "ignores webhook delivery while Telegram is in polling mode" do
    SettingsService.set(:telegram_update_mode, "polling")

    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("/whoami"),
      as: :json

    assert_response :not_found
  end

  test "rejects webhook requests with invalid secret" do
    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "wrong" },
      params: telegram_update("/whoami"),
      as: :json

    assert_response :unauthorized
  end

  test "responds to commands for authorized groups" do
    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("/whoami"),
      as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "sendMessage", body["method"]
    assert_equal "Telegram requests are owned by userone.", body["text"]
  end

  test "returns an approval code for unauthorized groups" do
    assert_difference "TelegramChatAuthorization.count", 1 do
      post integrations_telegram_webhook_path,
        headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
        params: telegram_update("/whoami", chat_id: "-100999"),
        as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_match(/Approval code: \d{6}/, body["text"])

    authorization = TelegramChatAuthorization.find_by!(chat_id: "-100999")
    assert_equal "Shelfarr Readers", authorization.chat_title
    assert_not authorization.approved?
    assert authorization.code_digest.present?
  end

  test "accepts commands from approved Telegram groups" do
    TelegramChatAuthorization.create!(chat_id: "-100999", chat_title: "Approved Group", approved_at: Time.current)

    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("/whoami", chat_id: "-100999"),
      as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Telegram requests are owned by userone.", body["text"]
  end

  test "returns concise search results with numbered request buttons" do
    search_result = MetadataService::SearchResult.new(
      source: "openlibrary",
      source_id: "OL_TELEGRAM_SEARCH_123W",
      title: "Telegram Search Book With A Very Long Title",
      author: "Telegram Author",
      description: nil,
      year: 2024,
      cover_url: nil,
      has_audiobook: nil,
      has_ebook: nil,
      series_name: nil,
      series_position: nil
    )

    MetadataService.stub(:search, [ search_result ]) do
      post integrations_telegram_webhook_path,
        headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
        params: telegram_update("/search Telegram Search", update_id: 124),
        as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_includes body["text"], "1. Telegram Search Book With A Very Long Title by Telegram Author"
    assert_includes body["text"], "Choose a format below."
    assert_not_includes body["text"], search_result.work_id
    assert_equal "1. Ebook", body.dig("reply_markup", "inline_keyboard", 0, 0, "text")
    assert_equal "1. Audio", body.dig("reply_markup", "inline_keyboard", 0, 1, "text")
  end

  test "rejects paused Telegram groups without issuing a new approval code" do
    TelegramChatAuthorization.create!(
      chat_id: "-100123",
      chat_title: "Paused Group",
      approved_at: Time.current,
      paused_at: Time.current
    )

    assert_no_difference "TelegramChatAuthorization.count" do
      post integrations_telegram_webhook_path,
        headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
        params: telegram_update("/whoami"),
        as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_includes body["text"], "paused in Shelfarr"
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

    request = Request.last
    assert_equal "telegram", request.created_via
    assert_equal "telegram", request.external_source
    assert_equal @user, request.user
    assert_equal "42", request.external_user_id
    assert_equal "-100123", request.external_chat_id
  end

  test "ignores duplicate telegram updates" do
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

  test "creates requests from cached inline callback query with source work ids" do
    book = Book.create!(
      title: "Existing Google Book",
      book_type: :ebook,
      google_books_id: "gb-telegram-cache"
    )
    Request.create!(book: book, user: @user, status: :pending)

    candidate = MetadataSearch::Candidate.new(
      canonical_key: "openlibrary:OL_TELEGRAM_CACHE_W",
      title: "Existing Google Book",
      author: "Author",
      year: 2024,
      description: nil,
      cover_url: nil,
      series_name: nil,
      series_position: nil,
      has_ebook: nil,
      has_audiobook: nil,
      sources: [
        { source: "openlibrary", source_id: "OL_TELEGRAM_CACHE_W", source_name: "Open Library", source_url: nil, work_id: "openlibrary:OL_TELEGRAM_CACHE_W" },
        { source: "google_books", source_id: "gb-telegram-cache", source_name: "Google Books", source_url: nil, work_id: "google_books:gb-telegram-cache" }
      ],
      editions: [],
      confidence: 90
    )
    token = Integrations::Telegram::SearchResultCache.store(candidate)

    assert_no_difference "Request.count" do
      post integrations_telegram_webhook_path,
        headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
        params: telegram_callback("req|#{token}|ebook"),
        as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_includes body["text"], "already has an active request"
  end

  test "creates requests from inline callback query" do
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

  test "rejects commands from private chats" do
    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("/whoami", chat_id: "42", chat_type: "private"),
      as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Shelfarr only accepts Telegram commands from authorized groups.", body["text"]
  end

  test "link command is not supported for group authorization" do
    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("/link userone 000000"),
      as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Unknown command. Use /help for available commands.", body["text"]
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
    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("hello"),
      as: :json

    assert_response :success
    assert_empty response.body
  end

  test "ignores commands addressed to another bot" do
    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("/whoami@OtherBot"),
      as: :json

    assert_response :success
    assert_empty response.body
  end

  test "supports mention-first commands addressed to the bot" do
    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_update("@ShelfarrBot /whoami"),
      as: :json

    assert_response :success
    assert_equal "Telegram requests are owned by userone.", JSON.parse(response.body)["text"]
  end

  test "handles unknown callbacks" do
    post integrations_telegram_webhook_path,
      headers: { "X-Telegram-Bot-Api-Secret-Token" => "telegram-secret" },
      params: telegram_callback("unknown|openlibrary:OL_UNLINKED_CALLBACK_123W|ebook"),
      as: :json

    assert_response :success
    assert_equal "Unknown action.", JSON.parse(response.body)["text"]
  end

  private

  def telegram_update(text, chat_id: "-100123", sender_id: 42, update_id: 123, chat_type: "supergroup")
    {
      update_id: update_id,
      message: {
        message_id: 456,
        text: text,
        chat: {
          id: chat_id,
          type: chat_type,
          title: "Shelfarr Readers"
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
