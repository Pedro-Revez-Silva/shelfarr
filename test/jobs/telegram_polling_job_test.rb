# frozen_string_literal: true

require "test_helper"

class TelegramPollingJobTest < ActiveJob::TestCase
  setup do
    clear_enqueued_jobs
    TelegramPollingJob.clear_schedule!
    SettingsService.set(:telegram_enabled, true)
    SettingsService.set(:telegram_update_mode, "polling")
    SettingsService.set(:telegram_bot_token, "telegram-token")
    SettingsService.set(:telegram_bot_username, "ShelfarrBot")
    SettingsService.set(:telegram_webhook_secret, "")
    SettingsService.set(:telegram_allowed_chat_ids, "-100123")
    SettingsService.set(:telegram_request_username, "userone")
  end

  teardown do
    TelegramPollingJob.clear_schedule!
  end

  test "polls Telegram updates and delivers command responses through the bot API" do
    VCR.turned_off do
      get_updates = stub_request(:post, "https://api.telegram.org/bottelegram-token/getUpdates")
        .with do |request|
          body = JSON.parse(request.body)
          body["timeout"] == TelegramPollingJob::POLL_TIMEOUT_SECONDS &&
            body["limit"] == TelegramPollingJob::POLL_LIMIT
        end
        .to_return(
          status: 200,
          body: {
            ok: true,
            result: [
              telegram_update("/whoami", update_id: 700001)
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      send_message = stub_request(:post, "https://api.telegram.org/bottelegram-token/sendMessage")
        .with do |request|
          body = JSON.parse(request.body)
          body["chat_id"] == "-100123" &&
            body["text"] == "Telegram requests are owned by userone."
        end
        .to_return(status: 200, body: { ok: true, result: {} }.to_json, headers: { "Content-Type" => "application/json" })

      assert_enqueued_with(job: TelegramPollingJob) do
        TelegramPollingJob.perform_now
      end

      assert_requested get_updates
      assert_requested send_message
      assert TelegramUpdate.exists?(update_id: "700001")
    end
  end

  test "uses the next update offset when previous Telegram updates exist" do
    TelegramUpdate.create!(update_id: "700010", telegram_user_id: "42", chat_id: "-100123", command: "/whoami")

    VCR.turned_off do
      get_updates = stub_request(:post, "https://api.telegram.org/bottelegram-token/getUpdates")
        .with do |request|
          JSON.parse(request.body)["offset"] == 700011
        end
        .to_return(status: 200, body: { ok: true, result: [] }.to_json, headers: { "Content-Type" => "application/json" })

      TelegramPollingJob.perform_now

      assert_requested get_updates
    end
  end

  test "does not poll when Telegram is in webhook mode" do
    SettingsService.set(:telegram_update_mode, "webhook")

    VCR.turned_off do
      get_updates = stub_request(:post, "https://api.telegram.org/bottelegram-token/getUpdates")

      TelegramPollingJob.perform_now

      assert_not_requested get_updates
    end
  end

  test "ensure_running enqueues one polling job when configured for polling" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    begin
      assert_enqueued_with(job: TelegramPollingJob) do
        TelegramPollingJob.ensure_running!
      end

      assert_no_enqueued_jobs(only: TelegramPollingJob) do
        TelegramPollingJob.ensure_running!
      end
    ensure
      Rails.cache = original_cache
    end
  end

  test "ensure_running does not enqueue when a polling job is already pending" do
    TelegramPollingJob.stub(:polling_job_pending?, true) do
      assert_no_enqueued_jobs(only: TelegramPollingJob) do
        TelegramPollingJob.ensure_running!
      end
    end
  end

  test "perform does not schedule another polling job when another one is pending" do
    VCR.turned_off do
      stub_request(:post, "https://api.telegram.org/bottelegram-token/getUpdates")
        .to_return(status: 200, body: { ok: true, result: [] }.to_json, headers: { "Content-Type" => "application/json" })

      TelegramPollingJob.stub(:polling_job_pending?, true) do
        assert_no_enqueued_jobs(only: TelegramPollingJob) do
          TelegramPollingJob.perform_now
        end
      end
    end
  end

  private

  def telegram_update(text, update_id:)
    {
      update_id: update_id,
      message: {
        message_id: 456,
        text: text,
        chat: {
          id: -100123,
          type: "supergroup",
          title: "Shelfarr Readers"
        },
        from: {
          id: 42,
          username: "telegramuser"
        }
      }
    }
  end
end
