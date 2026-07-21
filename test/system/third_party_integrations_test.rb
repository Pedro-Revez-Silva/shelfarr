require "application_system_test_case"

class ThirdPartyIntegrationsTest < ApplicationSystemTestCase
  setup do
    @admin = users(:two)
    @user = users(:one)
    SettingsService.set(:telegram_enabled, false)
    SettingsService.set(:telegram_bot_token, "")
    SettingsService.set(:telegram_bot_username, "")
    SettingsService.set(:telegram_webhook_secret, "")
    SettingsService.set(:telegram_allowed_chat_ids, "")
    SettingsService.set(:telegram_notification_events, "request_completed,request_failed,request_attention")
  end

  test "admin opens integration settings after Turbo navigation" do
    sign_in_as(@admin)

    visit admin_root_path
    click_link "Settings"

    assert_selector "#settings-tabs [role='tablist']"
    click_button "Integrations"
    assert_field "Audiobookshelf URL"

    click_link "Admin", match: :first
    assert_current_path admin_root_path
    page.go_back

    assert_current_path admin_settings_path
    assert_field "Audiobookshelf URL"
  end

  test "admin opens Audible Backup tabs after Turbo navigation" do
    sign_in_as(@admin)

    visit admin_root_path
    click_link "Audible Backup (Beta)"

    assert_selector "#audible-backup-tabs [role='tablist']"
    click_button "Automation"
    assert_text "Audible automation"
    assert_no_field "Companion URL"
  end

  test "admin configures Telegram settings and verifies the bot" do
    sign_in_as(@admin)

    visit admin_settings_path
    click_button "Integrations"

    assert_text "Telegram Bot"
    assert_field "Telegram Update Mode", with: "polling"
    assert_link "Test Telegram Bot"
    assert_link "Set Telegram Webhook"

    check "Telegram Enabled"
    select "Polling", from: "Telegram Update Mode"
    fill_in "Telegram Bot Token", with: "telegram-token"
    fill_in "Telegram Bot Username", with: "@ShelfarrBot"
    fill_in "Telegram Webhook Secret", with: "telegram-secret"
    fill_in "Telegram Allowed Chat Ids", with: "-100123"
    fill_in "Telegram Notification Events", with: "request_completed,request_failed"

    click_button "Save All"

    assert_text "Settings updated successfully."
    assert_equal true, SettingsService.get(:telegram_enabled)
    assert_equal "telegram-token", SettingsService.get(:telegram_bot_token)
    assert_equal "@ShelfarrBot", SettingsService.get(:telegram_bot_username)
    assert_equal "-100123", SettingsService.get(:telegram_allowed_chat_ids)

    stub_request(:post, "https://api.telegram.org/bottelegram-token/getMe")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { ok: true, result: { username: "ShelfarrBot" } }.to_json
      )

    click_link "Test Telegram Bot"

    assert_text "Telegram connection successful: @ShelfarrBot"
  end

  test "admin authorizes a Telegram group with a pairing code" do
    _authorization, code = TelegramChatAuthorization.issue!(
      chat_id: "-100999",
      chat_title: "Book Club",
      requested_by_telegram_user_id: "42",
      requested_by_telegram_username: "reader"
    )
    sign_in_as(@admin)

    visit admin_settings_path
    click_button "Integrations"

    assert_text "Telegram Group Authorization"
    fill_in "telegram_group_code", with: code
    click_button "Authorize Group"

    assert_text "Telegram group authorized: Book Club"
    click_button "Integrations"
    assert_text "Authorized"
    assert TelegramChatAuthorization.find_by!(chat_id: "-100999").approved?
  end

  test "admin pauses resumes and deletes a Telegram group" do
    authorization = TelegramChatAuthorization.create!(
      chat_id: "-100999",
      chat_title: "Book Club",
      approved_at: Time.current,
      approved_by: @admin
    )
    sign_in_as(@admin)

    visit admin_settings_path
    click_button "Integrations"

    assert_text "Book Club"
    assert_text "Authorized"

    click_button "Pause Book Club"
    assert_text "Telegram group paused: Book Club"
    click_button "Integrations"
    assert_text "Paused"
    assert authorization.reload.paused?

    click_button "Resume Book Club"
    assert_text "Telegram group resumed: Book Club"
    click_button "Integrations"
    assert_text "Authorized"
    assert_not authorization.reload.paused?

    click_button "Delete Book Club"
    assert_text "Telegram group removed: Book Club"
    click_button "Integrations"
    assert_no_text "-100999"
    assert_not TelegramChatAuthorization.exists?(authorization.id)
  end

  test "user creates and revokes an API token from profile" do
    sign_in_as(@user)

    visit profile_path

    assert_text "API tokens"

    fill_in "Token name", with: "Browser system token"
    click_button "Create API Token"

    assert_text(/API token created: shf_[A-Za-z0-9]+/)
    assert_text "Browser system token"
    token = @user.api_tokens.find_by!(name: "Browser system token")
    assert_not token.revoked?

    click_button "Revoke"

    assert_text "API token revoked."
    assert_text "revoked"
    assert token.reload.revoked?
  end
end
