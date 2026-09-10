require "application_system_test_case"

class SettingsVisibilityTest < ApplicationSystemTestCase
  SAVE_STATUS = "[data-settings-form-target~='status']"

  setup do
    clear_settings_env!
    @admin = users(:two)
    SettingsService.set(:indexer_provider, "none")
    SettingsService.set(:indexer_search_scope, "broad")
    SettingsService.set(:library_platform, "audiobookshelf")
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobookshelf_api_key, "")
    SettingsService.set(:zlibrary_enabled, false)
    SettingsService.set(:telegram_enabled, false)
    SettingsService.set(:max_retries, 10)

    # Saving connection settings also runs health checks. These tests exercise
    # settings persistence even when the configured services are unavailable.
    stub_request(:any, %r{\Ahttps://(?:saved|draft)-(?:prowlarr|jackett|bookorbit|grimmory)\.example\.com/})
      .to_return(status: 503, body: "Service unavailable")
  end

  teardown do
    restore_settings_env!
    page.current_window.resize_to(1400, 1400)
  end

  test "saving another indexer excludes inactive credentials and preserves their unsaved drafts" do
    SettingsService.set(:indexer_provider, "prowlarr")
    SettingsService.set(:prowlarr_url, "https://saved-prowlarr.example.com")
    SettingsService.set(:prowlarr_api_key, "saved-prowlarr-key")
    SettingsService.set(:prowlarr_tags, "saved-tag")
    open_settings

    fill_in "Prowlarr Url", with: "https://draft-prowlarr.example.com"
    fill_in "Prowlarr Api Key", with: "draft-prowlarr-key"
    fill_in "Prowlarr Tags", with: "draft-tag"
    select "Jackett", from: "Provider"
    fill_in "Jackett Url", with: "https://draft-jackett.example.com"
    fill_in "Jackett Api Key", with: "draft-jackett-key"

    save_all

    assert_equal "jackett", SettingsService.get(:indexer_provider)
    assert_equal "draft-jackett-key", SettingsService.get(:jackett_api_key)
    assert_equal "https://saved-prowlarr.example.com", SettingsService.get(:prowlarr_url)
    assert_equal "saved-prowlarr-key", SettingsService.get(:prowlarr_api_key)
    assert_equal "saved-tag", SettingsService.get(:prowlarr_tags)
    assert_no_submitted_settings "prowlarr_url", "prowlarr_api_key", "prowlarr_tags"
    assert_no_field "Prowlarr Api Key"
    assert_field "Jackett Api Key", with: ""
    assert_selector SAVE_STATUS, exact_text: "Unsaved provider drafts. Switch providers to save them."

    select "Prowlarr", from: "Provider"

    assert_field "Prowlarr Url", with: "https://draft-prowlarr.example.com"
    assert_field "Prowlarr Api Key", with: "draft-prowlarr-key"
    assert_field "Prowlarr Tags", with: "draft-tag"
    save_all

    assert_equal "prowlarr", SettingsService.get(:indexer_provider)
    assert_equal "https://draft-prowlarr.example.com", SettingsService.get(:prowlarr_url)
    assert_equal "draft-prowlarr-key", SettingsService.get(:prowlarr_api_key)
    assert_equal "draft-tag", SettingsService.get(:prowlarr_tags)
    assert_field "Prowlarr Api Key", with: ""
    assert_selector SAVE_STATUS, exact_text: "Saved."
  end

  test "library credentials remain separate while switching and saving active platforms" do
    SettingsService.set(:bookorbit_url, "https://saved-bookorbit.example.com")
    SettingsService.set(:bookorbit_username, "saved-bookorbit-user")
    SettingsService.set(:bookorbit_password, "saved-bookorbit-password")
    open_settings
    click_button "Integrations"

    assert_field "Audiobookshelf URL"
    assert_no_field "BookOrbit Username"
    assert_no_field "Grimmory Username"
    select "BookOrbit", from: "Active Library Platform"
    assert_no_field "Audiobookshelf URL"
    assert_field "BookOrbit Username", with: "saved-bookorbit-user"
    assert_field "BookOrbit Password", with: "", placeholder: "********"

    fill_in "BookOrbit URL", with: "https://draft-bookorbit.example.com"
    fill_in "BookOrbit Username", with: "draft-bookorbit-user"
    fill_in "BookOrbit Password", with: "draft-bookorbit-password"
    select "Grimmory", from: "Active Library Platform"
    fill_in "Grimmory URL", with: "https://draft-grimmory.example.com"
    fill_in "Grimmory Username", with: "draft-grimmory-user"
    fill_in "Grimmory Password", with: "draft-grimmory-password"

    save_all

    assert_equal "grimmory", SettingsService.get(:library_platform)
    assert_equal "draft-grimmory-user", SettingsService.get(:grimmory_username)
    assert_equal "draft-grimmory-password", SettingsService.get(:grimmory_password)
    assert_equal "https://saved-bookorbit.example.com", SettingsService.get(:bookorbit_url)
    assert_equal "saved-bookorbit-user", SettingsService.get(:bookorbit_username)
    assert_equal "saved-bookorbit-password", SettingsService.get(:bookorbit_password)
    assert_no_submitted_settings "bookorbit_url", "bookorbit_username", "bookorbit_password",
      "audiobookshelf_url", "audiobookshelf_api_key"
    assert_field "Grimmory Password", with: ""
    assert_selector SAVE_STATUS, exact_text: "Unsaved provider drafts. Switch providers to save them."

    select "BookOrbit", from: "Active Library Platform"

    assert_field "BookOrbit URL", with: "https://draft-bookorbit.example.com"
    assert_field "BookOrbit Username", with: "draft-bookorbit-user"
    assert_field "BookOrbit Password", with: "draft-bookorbit-password"
    save_all

    assert_equal "bookorbit", SettingsService.get(:library_platform)
    assert_equal "https://draft-bookorbit.example.com", SettingsService.get(:bookorbit_url)
    assert_equal "draft-bookorbit-user", SettingsService.get(:bookorbit_username)
    assert_equal "draft-bookorbit-password", SettingsService.get(:bookorbit_password)
    assert_equal "draft-grimmory-password", SettingsService.get(:grimmory_password)
    assert_no_submitted_settings "grimmory_url", "grimmory_username", "grimmory_password"
    assert_selector SAVE_STATUS, exact_text: "Saved."
  end

  test "custom categories remain saved when their controls are hidden by another search scope" do
    SettingsService.set(:indexer_custom_audiobook_categories, "3030")
    SettingsService.set(:indexer_custom_ebook_categories, "7020")
    SettingsService.set(:indexer_custom_comicbook_categories, "7030")
    open_settings

    category_fields = {
      "settings_indexer_custom_audiobook_categories" => "3030",
      "settings_indexer_custom_ebook_categories" => "7020",
      "settings_indexer_custom_comicbook_categories" => "7030"
    }
    category_fields.each_key { |field| assert_no_field field }
    select "Custom", from: "Search Scope"
    category_fields.each { |field, value| assert_field field, with: value }
    assert_selector SAVE_STATUS, exact_text: "Saved."

    # Changing scope immediately after blur must not lose an autosave that is
    # still pending for the now-hidden category field.
    fill_in "settings_indexer_custom_comicbook_categories", with: "7030, 7020"
    select "Broad (recommended)", from: "Search Scope"
    category_fields.each_key { |field| assert_no_field field }
    assert_selector SAVE_STATUS, exact_text: "Saved."

    assert_equal "broad", SettingsService.get(:indexer_search_scope)
    assert_equal "3030", SettingsService.get(:indexer_custom_audiobook_categories)
    assert_equal "7020", SettingsService.get(:indexer_custom_ebook_categories)
    assert_equal "7030, 7020", SettingsService.get(:indexer_custom_comicbook_categories)

    click_button "Queue & System"
    fill_in "Max Retries", with: "19"
    save_all
    assert_equal 19, SettingsService.get(:max_retries)
    click_button "Search"
    select "Custom", from: "Search Scope"
    assert_field "settings_indexer_custom_comicbook_categories", with: "7030, 7020"
    assert_selector SAVE_STATUS, exact_text: "Saved."
  end

  test "a collapsed disabled direct source can be enabled and disabled without losing saved credentials" do
    SettingsService.set(:zlibrary_url, "https://zlibrary.example.com")
    SettingsService.set(:zlibrary_email, "saved-reader@example.com")
    SettingsService.set(:zlibrary_password, "saved-zlibrary-password")
    open_settings

    assert_selector "summary", text: "Z-Library"
    assert_no_field "Zlibrary Email"
    find("summary", text: "Z-Library").click
    assert_field "Zlibrary Email", with: "saved-reader@example.com"
    assert_field "Zlibrary Password", with: "", placeholder: "********"
    check "Zlibrary Enabled"
    save_all

    assert SettingsService.get(:zlibrary_enabled)
    assert_equal "saved-reader@example.com", SettingsService.get(:zlibrary_email)
    assert_equal "saved-zlibrary-password", SettingsService.get(:zlibrary_password)
    assert_selector SAVE_STATUS, exact_text: "Saved."

    find("summary", text: "Z-Library").click
    assert_no_field "Zlibrary Email"
    save_all
    assert_equal "saved-zlibrary-password", SettingsService.get(:zlibrary_password)
    find("summary", text: "Z-Library").click
    uncheck "Zlibrary Enabled"
    save_all

    assert_not SettingsService.get(:zlibrary_enabled)
    visit admin_settings_path
    assert_no_field "Zlibrary Email"
    find("summary", text: "Z-Library").click
    assert_field "Zlibrary Email", with: "saved-reader@example.com"
    assert_field "Zlibrary Password", with: "", placeholder: "********"
    assert_equal "https://zlibrary.example.com", SettingsService.get(:zlibrary_url)
    assert_equal "saved-zlibrary-password", SettingsService.get(:zlibrary_password)
  end

  test "save controls and successful save feedback stay reachable while scrolling on mobile" do
    page.current_window.resize_to(390, 844)
    open_settings
    click_button "Downloads"
    fill_in "Audiobook Path Template", with: "{author}/{title}/{year}"
    page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")

    assert_in_viewport find_button("Save All")
    save_all

    assert_equal "{author}/{title}/{year}", SettingsService.get(:audiobook_path_template)
    assert_selector SAVE_STATUS, exact_text: "Saved."
    page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")
    assert_in_viewport find_button("Save All")
    assert_in_viewport find(SAVE_STATUS)
  end

  private

  def open_settings
    sign_in_as(@admin)
    visit admin_settings_path
    assert_selector "#settings-tabs [role='tablist']"
    page.execute_script <<~JAVASCRIPT
      const originalFetch = window.fetch.bind(window)
      window.settingsVisibilitySubmissions = []
      window.fetch = (input, options) => {
        const url = new URL(typeof input === "string" ? input : input.url, window.location.origin)
        if (url.pathname !== "/admin/settings/bulk_update") return originalFetch(input, options)

        window.settingsVisibilitySubmissions.push({
          fields: Array.from(options.body.keys()),
          manualKeys: (options.body.get("manual_keys") || "").split(",")
        })
        return originalFetch(input, options).then((response) => {
          document.documentElement.dataset.settingsVisibilitySaves = window.settingsVisibilitySubmissions.length
          return response
        })
      }
    JAVASCRIPT
  end

  def save_all
    next_save = page.evaluate_script("window.settingsVisibilitySubmissions.length") + 1
    click_button "Save All"
    assert_selector "html[data-settings-visibility-saves='#{next_save}']"
    assert_selector "form[data-settings-form-target~='form']:not([inert])[aria-busy='false']", visible: :all
    assert_text "Settings updated successfully."
  end

  def assert_no_submitted_settings(*keys)
    submission = page.evaluate_script("window.settingsVisibilitySubmissions.at(-1)")
    keys.each do |key|
      assert_not_includes submission.fetch("fields"), "settings[#{key}]"
      assert_not_includes submission.fetch("manualKeys"), key
    end
  end

  def assert_in_viewport(element)
    visible_and_reachable = page.evaluate_script(<<~JAVASCRIPT, element)
      ((element) => {
        const rect = element.getBoundingClientRect()
        const hit = document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2)
        return rect.width > 0 && rect.height > 0 && rect.top >= 0 && rect.left >= 0 &&
          rect.bottom <= window.innerHeight && rect.right <= window.innerWidth && element.contains(hit)
      })(arguments[0])
    JAVASCRIPT
    assert visible_and_reachable, "Expected #{element.text.presence || element[:value]} to be inside the viewport and unobscured"
  end
end
