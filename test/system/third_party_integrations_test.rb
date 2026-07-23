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
    SettingsService.set(:bookorbit_username, "")
    SettingsService.set(:bookorbit_password, "")
    SettingsService.set(:max_retries, 10)
    SettingsService.set(:rate_limit_delay, 2)
    SettingsService.set(:audiobook_path_template, "{author}/{title}")
    SettingsService.set(:ebooks_com_enabled, false)
    SettingsService.set(:ebooks_com_country_code, "")
    SettingsService.set(:open_library_enabled, false)
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

  test "history navigation waits for a pending autosave" do
    sign_in_as(@admin)
    visit admin_root_path
    click_link "Settings"
    click_button "Queue & System"

    page.execute_script <<~JAVASCRIPT
      const originalFetch = window.fetch.bind(window)
      window.fetch = (input, options) => {
        const url = typeof input === "string" ? input : input.url
        if (!url.includes("/admin/settings/bulk_update")) return originalFetch(input, options)

        document.querySelector("[data-settings-form-target='form']").dataset.historyAutosaveStarted = "true"
        return new Promise((resolve) => {
          window.releaseHistoryAutosave = () => resolve(originalFetch(input, options))
        })
      }
    JAVASCRIPT

    fill_in "Max Retries", with: "29"
    page.go_back

    assert_current_path admin_settings_path
    assert_selector "form[data-history-autosave-started='true']"
    assert_no_text "Admin Dashboard"
    page.execute_script("window.releaseHistoryAutosave()")
    assert_text "Admin Dashboard"
    assert_equal 29, SettingsService.get(:max_retries)

    page.go_forward
    assert_current_path admin_settings_path
    assert_selector "form[data-settings-form-target='form']:not([inert])[aria-busy='false']", visible: :all
    assert_selector "[data-settings-form-target='status'].hidden", visible: :all
  end

  test "Turbo visit waits for a pending autosave" do
    sign_in_as(@admin)
    visit admin_settings_path
    click_button "Queue & System"

    page.execute_script <<~JAVASCRIPT
      const originalFetch = window.fetch.bind(window)
      window.fetch = (input, options) => {
        const url = typeof input === "string" ? input : input.url
        if (!url.includes("/admin/settings/bulk_update")) return originalFetch(input, options)

        document.querySelector("[data-settings-form-target='form']").dataset.visitAutosaveStarted = "true"
        return new Promise((resolve) => {
          window.releaseVisitAutosave = () => resolve(originalFetch(input, options))
        })
      }
    JAVASCRIPT

    fill_in "Max Retries", with: "32"
    find("h1", text: "Settings").click
    click_link "Admin", match: :first

    assert_current_path admin_settings_path
    assert_selector "form[data-visit-autosave-started='true']"
    assert_no_text "Admin Dashboard"
    page.execute_script("window.releaseVisitAutosave()")

    assert_text "Admin Dashboard"
    assert_current_path admin_root_path
    assert_equal 32, SettingsService.get(:max_retries)
  end

  test "Turbo visit confirms deliberate unsaved credential changes" do
    sign_in_as(@admin)
    visit admin_settings_path
    click_button "Integrations"
    fill_in "BookOrbit Username", with: "manual-draft"

    dismiss_confirm do
      click_link "Admin", match: :first
    end

    assert_current_path admin_settings_path
    assert_field "BookOrbit Username", with: "manual-draft"

    accept_confirm do
      click_link "Admin", match: :first
    end

    assert_current_path admin_root_path
    assert_equal "", SettingsService.get(:bookorbit_username)
  end

  test "history navigation confirms deliberate unsaved credential changes" do
    sign_in_as(@admin)
    visit admin_root_path
    click_link "Settings"
    click_button "Integrations"
    fill_in "BookOrbit Username", with: "history-draft"

    dismiss_confirm { page.go_back }

    assert_current_path admin_settings_path
    assert_field "BookOrbit Username", with: "history-draft"

    accept_confirm { page.go_back }

    assert_current_path admin_root_path
    assert_equal "", SettingsService.get(:bookorbit_username)
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

    click_link "Test Telegram Bot"
    assert_text "Save all changes before running this action."

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

  test "settings autosave ignores autofilled credentials and preserves the live form" do
    sign_in_as(@admin)
    visit admin_settings_path
    click_button "Integrations"

    page.execute_script <<~JAVASCRIPT
      const originalFetch = window.fetch.bind(window)
      window.settingsBulkUpdateCount = 0
      window.fetch = (input, options) => {
        const url = typeof input === "string" ? input : input.url
        if (url.includes("/admin/settings/bulk_update")) window.settingsBulkUpdateCount += 1
        return originalFetch(input, options)
      }
      document.querySelector("#settings-form").dataset.autofillTestNode = "original"

      const username = document.querySelector("#settings_bookorbit_username")
      const password = document.querySelector("#settings_bookorbit_password")
      username.value = "autofilled-user"
      password.value = "autofilled-password"
      username.dispatchEvent(new Event("change", { bubbles: true }))
      password.dispatchEvent(new Event("change", { bubbles: true }))
    JAVASCRIPT

    sleep 1
    assert_equal 0, page.evaluate_script("window.settingsBulkUpdateCount")
    assert_selector "#settings-form[data-autofill-test-node='original']"

    click_button "Queue & System"
    page.execute_script <<~JAVASCRIPT
      const staleDraft = document.querySelector("#settings_rate_limit_delay")
      staleDraft.value = "7"
      staleDraft.dispatchEvent(new Event("input", { bubbles: true }))
    JAVASCRIPT
    fill_in "Max Retries", with: "22"
    find("h1", text: "Settings").click

    assert_selector "[data-settings-form-target='status'].hidden", visible: :all
    assert_no_text "Settings updated successfully."
    assert_equal 22, SettingsService.get(:max_retries)
    assert_equal 2, SettingsService.get(:rate_limit_delay)
    assert_equal "", SettingsService.get(:bookorbit_username)
    assert_equal "", SettingsService.get(:bookorbit_password)
    assert_field "Rate Limit Delay", with: "7"
    assert_equal 1, page.evaluate_script("window.settingsBulkUpdateCount")
    assert_selector "#settings-form[data-autofill-test-node='original']"

    click_button "Integrations"
    assert_field "BookOrbit Username", with: "autofilled-user"
    assert_field "BookOrbit Password", with: "autofilled-password"
    page.execute_script <<~JAVASCRIPT
      document.querySelector("[data-settings-form-target='form']").addEventListener("submit", (event) => {
        window.lastSettingsSubmit = {
          submitter: event.submitter?.name,
          fields: Array.from(new FormData(event.target, event.submitter).keys())
        }
      })
    JAVASCRIPT

    click_button "Save All"

    assert_text "Settings updated successfully."
    submission = page.evaluate_script("window.lastSettingsSubmit")
    assert_equal "commit", submission.fetch("submitter")
    assert_not_includes submission.fetch("fields"), "autosave"
    assert_equal "", SettingsService.get(:bookorbit_username)
    assert_equal "", SettingsService.get(:bookorbit_password)
    assert_field "BookOrbit Password", with: ""
    assert_equal 2, page.evaluate_script("window.settingsBulkUpdateCount")
    assert_selector "#settings-form[data-autofill-test-node='original']"
    find("button[aria-label='Dismiss notification']", visible: :all).click

    fill_in "BookOrbit Username", with: "deliberate-user"
    fill_in "BookOrbit Password", with: "deliberate-password"
    assert_text "Unsaved changes. Click Save All."
    click_button "Save All"

    assert_text "Settings updated successfully."
    assert_equal "deliberate-user", SettingsService.get(:bookorbit_username)
    assert_equal "deliberate-password", SettingsService.get(:bookorbit_password)
    assert_equal 3, page.evaluate_script("window.settingsBulkUpdateCount")
  end

  test "switching indexer provider ignores a touched field that becomes disabled" do
    SettingsService.set(:indexer_provider, "prowlarr")
    SettingsService.set(:prowlarr_url, "https://prowlarr.example.com")
    sign_in_as(@admin)
    visit admin_settings_path

    fill_in "Prowlarr Url", with: "https://draft-prowlarr.example.com"
    select "Jackett", from: "Provider"
    click_button "Save All"

    assert_text "Settings updated successfully."
    assert_equal "jackett", SettingsService.get(:indexer_provider)
    assert_equal "https://prowlarr.example.com", SettingsService.get(:prowlarr_url)
  end

  test "settings form blocks overlapping edits while an autosave is in flight" do
    sign_in_as(@admin)
    visit admin_settings_path
    click_button "Integrations"
    fill_in "BookOrbit Username", with: "manual-user"
    fill_in "BookOrbit Password", with: "manual-password"
    click_button "Queue & System"

    page.execute_script <<~JAVASCRIPT
      const originalFetch = window.fetch.bind(window)
      let activeRequests = 0
      window.settingsFetchCount = 0
      window.settingsMaxConcurrentFetches = 0
      window.fetch = (input, options) => {
        const url = typeof input === "string" ? input : input.url
        if (!url.includes("/admin/settings/bulk_update")) return originalFetch(input, options)

        window.settingsFetchCount += 1
        activeRequests += 1
        window.settingsMaxConcurrentFetches = Math.max(window.settingsMaxConcurrentFetches, activeRequests)
        document.documentElement.dataset.settingsFetchCount = window.settingsFetchCount
        const performFetch = () => originalFetch(input, options).finally(() => { activeRequests -= 1 })
        if (window.settingsFetchCount > 1) return performFetch()

        return new Promise((resolve) => {
          window.releaseSettingsAutosave = () => resolve(performFetch())
        })
      }
    JAVASCRIPT

    fill_in "Max Retries", with: "21"
    find_field("Rate Limit Delay").click

    assert_selector "html[data-settings-fetch-count='1']"
    assert_selector "form[data-settings-form-target='form'][inert][aria-busy='true']", visible: :all
    page.execute_script <<~JAVASCRIPT
      const field = document.querySelector("#settings_rate_limit_delay")
      field.value = "4"
      field.dispatchEvent(new Event("change", { bubbles: true }))
      const outsideLink = Array.from(document.querySelectorAll("a")).find((link) => link.textContent.trim() === "Admin")
      outsideLink.id = "outside-focus-target"
      outsideLink.focus()
    JAVASCRIPT
    assert_equal "outside-focus-target", page.evaluate_script("document.activeElement.id")
    assert_equal 1, page.evaluate_script("window.settingsFetchCount")
    page.execute_script("window.releaseSettingsAutosave()")

    assert_text "Unsaved changes. Click Save All."
    assert_selector "form[data-settings-form-target='form']:not([inert])[aria-busy='false']", visible: :all
    assert_equal "settings_rate_limit_delay", page.evaluate_script("document.activeElement.id")
    assert_equal 21, SettingsService.get(:max_retries)
    assert_equal 4, SettingsService.get(:rate_limit_delay)
    assert_equal 2, page.evaluate_script("window.settingsFetchCount")
    assert_equal 1, page.evaluate_script("window.settingsMaxConcurrentFetches")

    click_button "Save All"

    assert_selector "form[data-settings-form-target='form']:not([inert])[aria-busy='false']", visible: :all
    assert_equal "manual-user", SettingsService.get(:bookorbit_username)
    assert_equal "manual-password", SettingsService.get(:bookorbit_password)
  end

  test "in-form connection test waits for pending autosave" do
    sign_in_as(@admin)
    visit admin_settings_path
    click_button "Queue & System"

    page.execute_script <<~JAVASCRIPT
      const originalFetch = window.fetch.bind(window)
      window.settingsRequestOrder = []
      window.fetch = (input, options) => {
        const url = new URL(typeof input === "string" ? input : input.url, window.location.origin)
        if (!url.pathname.includes("/admin/settings/")) return originalFetch(input, options)

        window.settingsRequestOrder.push(url.pathname)
        document.documentElement.dataset.settingsRequestOrder = window.settingsRequestOrder.join(",")
        if (url.pathname !== "/admin/settings/bulk_update") return originalFetch(input, options)

        return new Promise((resolve) => {
          window.releaseSettingsAutosave = () => resolve(originalFetch(input, options))
        })
      }
    JAVASCRIPT

    fill_in "Max Retries", with: "26"
    find("h1", text: "Settings").click
    click_button "Search"
    click_button "Test eBooks.com Catalog"

    assert_selector "html[data-settings-request-order='/admin/settings/bulk_update']"
    assert_equal [ "/admin/settings/bulk_update" ], page.evaluate_script("window.settingsRequestOrder")
    page.execute_script("window.releaseSettingsAutosave()")

    assert_text "Enable eBooks.com and enter a valid two-letter buyer country code first.", wait: 10
    assert_selector "[data-settings-form-target='status'].hidden", visible: :all
    assert_equal 26, SettingsService.get(:max_retries)
    assert_equal [
      "/admin/settings/bulk_update",
      "/admin/settings/test_ebooks_com"
    ], page.evaluate_script("window.settingsRequestOrder")
  end

  test "Turbo method link waits for pending autosave" do
    sign_in_as(@admin)
    visit admin_settings_path
    click_button "Queue & System"

    page.execute_script <<~JAVASCRIPT
      const originalFetch = window.fetch.bind(window)
      window.settingsRequestOrder = []
      window.fetch = (input, options) => {
        const url = new URL(typeof input === "string" ? input : input.url, window.location.origin)
        if (!url.pathname.includes("/admin/settings/")) return originalFetch(input, options)

        window.settingsRequestOrder.push(url.pathname)
        document.documentElement.dataset.settingsRequestOrder = window.settingsRequestOrder.join(",")
        if (url.pathname !== "/admin/settings/bulk_update") return originalFetch(input, options)

        return new Promise((resolve) => {
          window.releaseSettingsAutosave = () => resolve(originalFetch(input, options))
        })
      }
    JAVASCRIPT

    fill_in "Max Retries", with: "30"
    click_button "Integrations"
    click_link "Test Open Library Connection"

    assert_selector "html[data-settings-request-order='/admin/settings/bulk_update']"
    assert_equal [ "/admin/settings/bulk_update" ], page.evaluate_script("window.settingsRequestOrder")
    page.execute_script("window.releaseSettingsAutosave()")

    assert_text "Open Library is not enabled."
    assert_equal 30, SettingsService.get(:max_retries)
    assert_equal [
      "/admin/settings/bulk_update",
      "/admin/settings/test_open_library"
    ], page.evaluate_script("window.settingsRequestOrder")
  end

  test "failed autosave retries its dirty keys with the next change" do
    sign_in_as(@admin)
    visit admin_settings_path
    click_button "Queue & System"

    page.execute_script <<~JAVASCRIPT
      const originalFetch = window.fetch.bind(window)
      let failed = false
      window.fetch = (input, options) => {
        const url = typeof input === "string" ? input : input.url
        if (!failed && url.includes("/admin/settings/bulk_update")) {
          failed = true
          return Promise.reject(new TypeError("simulated network failure"))
        }
        return originalFetch(input, options)
      }
    JAVASCRIPT

    fill_in "Max Retries", with: "27"
    find("h1", text: "Settings").click
    assert_selector "[data-settings-form-target='status']:not(.hidden)", visible: :all
    assert_text "Autosave failed. Change the setting to retry."
    assert_equal 10, SettingsService.get(:max_retries)

    fill_in "Rate Limit Delay", with: "4"
    find("h1", text: "Settings").click

    assert_selector "[data-settings-form-target='status'].hidden", visible: :all
    assert_equal 27, SettingsService.get(:max_retries)
    assert_equal 4, SettingsService.get(:rate_limit_delay)
  end

  test "failed explicit save keeps drafts and retries the full form" do
    sign_in_as(@admin)
    visit admin_settings_path
    click_button "Queue & System"

    page.execute_script <<~JAVASCRIPT
      const originalFetch = window.fetch.bind(window)
      let failed = false
      window.fetch = (input, options) => {
        const url = typeof input === "string" ? input : input.url
        if (!failed && url.includes("/admin/settings/bulk_update")) {
          failed = true
          document.documentElement.dataset.explicitSaveFailed = "true"
          return Promise.reject(new TypeError("simulated network failure"))
        }
        return originalFetch(input, options)
      }
    JAVASCRIPT

    fill_in "Max Retries", with: "28"
    click_button "Integrations"
    fill_in "BookOrbit Username", with: "retry-user"
    fill_in "BookOrbit Password", with: "retry-password"
    click_button "Save All"

    assert_selector "html[data-explicit-save-failed='true']"
    assert_selector "form[data-settings-form-target='form']:not([inert])[aria-busy='false']", visible: :all
    assert_equal 10, SettingsService.get(:max_retries)
    assert_equal "", SettingsService.get(:bookorbit_username)
    assert_field "BookOrbit Username", with: "retry-user"
    assert_field "BookOrbit Password", with: "retry-password"

    click_button "Save All"

    assert_text "Settings updated successfully."
    assert_equal 28, SettingsService.get(:max_retries)
    assert_equal "retry-user", SettingsService.get(:bookorbit_username)
    assert_equal "retry-password", SettingsService.get(:bookorbit_password)
  end

  test "invalid explicit save is atomic and preserves the live form" do
    sign_in_as(@admin)
    visit admin_settings_path
    click_button "Downloads"
    fill_in "Audiobook Path Template", with: "{title}/{invalid_var}"
    click_button "Integrations"
    fill_in "BookOrbit Username", with: "draft-user"

    click_button "Save All"

    assert_text "Audiobook Path Template"
    assert_text "Unknown variables: {invalid_var}"
    assert_equal "{author}/{title}", SettingsService.get(:audiobook_path_template)
    assert_equal "", SettingsService.get(:bookorbit_username)
    assert_field "BookOrbit Username", with: "draft-user"
    click_button "Downloads"
    assert_field "Audiobook Path Template", with: "{title}/{invalid_var}"

    fill_in "Audiobook Path Template", with: "{author}/{title}/{year}"
    click_button "Save All"

    assert_text "Settings updated successfully."
    assert_equal "{author}/{title}/{year}", SettingsService.get(:audiobook_path_template)
    assert_equal "draft-user", SettingsService.get(:bookorbit_username)
  end

  test "validation failure retries rejected dependencies after correction" do
    sign_in_as(@admin)
    visit admin_settings_path

    check "Show DRM-free eBooks.com Offers"

    assert_text "requires a valid ISO 3166-1 Buyer Country Code"
    assert_text "Autosave failed. Change the setting to retry."
    assert_not SettingsService.get(:ebooks_com_enabled)

    fill_in "Buyer Country Code", with: "US"
    find("h1", text: "Settings").click

    assert_selector "[data-settings-form-target='status'].hidden", visible: :all
    assert SettingsService.get(:ebooks_com_enabled)
    assert_equal "US", SettingsService.get(:ebooks_com_country_code)
  end

  test "failed autosave cancels deferred navigation until correction" do
    sign_in_as(@admin)
    visit admin_settings_path

    check "Show DRM-free eBooks.com Offers"
    click_link "Admin", match: :first

    assert_current_path admin_settings_path
    assert_text "requires a valid ISO 3166-1 Buyer Country Code"
    assert_not SettingsService.get(:ebooks_com_enabled)

    fill_in "Buyer Country Code", with: "US"
    find("h1", text: "Settings").click
    assert_selector "[data-settings-form-target='status'].hidden", visible: :all
    assert SettingsService.get(:ebooks_com_enabled)

    click_link "Admin", match: :first
    assert_current_path admin_root_path
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
    click_button "Queue & System"
    fill_in "Max Retries", with: "31"
    click_button "Integrations"

    page.execute_script <<~JAVASCRIPT
      const originalFetch = window.fetch.bind(window)
      window.fetch = (input, options) => {
        const url = typeof input === "string" ? input : input.url
        if (!url.includes("/admin/settings/bulk_update")) return originalFetch(input, options)

        document.documentElement.dataset.telegramAutosaveStarted = "true"
        return new Promise((resolve) => {
          window.releaseTelegramAutosave = () => resolve(originalFetch(input, options))
        })
      }
    JAVASCRIPT

    assert_text "Telegram Group Authorization"
    fill_in "telegram_group_code", with: code
    click_button "Authorize Group"

    assert_selector "html[data-telegram-autosave-started='true']"
    assert_not TelegramChatAuthorization.find_by!(chat_id: "-100999").approved?
    assert_no_text "Telegram group authorized: Book Club"
    page.execute_script("window.releaseTelegramAutosave()")

    assert_text "Telegram group authorized: Book Club"
    assert_equal 31, SettingsService.get(:max_retries)
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
