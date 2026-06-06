# frozen_string_literal: true

require "test_helper"

class Admin::SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:two)
    sign_in_as(@admin)
    AudiobookshelfClient.reset_connection!
    ProwlarrClient.reset_connection!
    FlaresolverrClient.reset_connection!
    ZLibraryClient.reset_connection! if defined?(ZLibraryClient)
  end

  teardown do
    AudiobookshelfClient.reset_connection!
    ProwlarrClient.reset_connection!
    FlaresolverrClient.reset_connection!
    ZLibraryClient.reset_connection! if defined?(ZLibraryClient)
  end

  test "index requires admin" do
    sign_out
    get admin_settings_url
    assert_response :redirect
  end

  test "index shows settings page" do
    get admin_settings_url
    assert_response :success
    assert_select "h1", "Settings"
  end

  test "index shows indexer provider dropdown" do
    get admin_settings_url

    assert_response :success
    assert_select "select[name='settings[indexer_provider]']"
    assert_select "option[value='prowlarr']", text: "Prowlarr"
    assert_select "option[value='jackett']", text: "Jackett"
  end

  test "index warns when disabling authentication is enabled" do
    get admin_settings_url

    assert_response :success
    assert_select "input[name='settings[auth_disabled]'][data-action='change->settings-form#handleAuthDisabledToggle']"
    assert_select "p", text: /Warning: This removes password and 2FA authentication/
  end

  test "index shows allow user uploads setting" do
    get admin_settings_url

    assert_response :success
    assert_select "label", text: "Allow User Uploads"
    assert_select "input[name='settings[allow_user_uploads]']"
    assert_select "p", text: /Allow non-admin users to upload book files directly/
  end

  test "index shows auto approve requests setting" do
    get admin_settings_url

    assert_response :success
    assert_select "label", text: "Auto Approve Requests"
    assert_select "input[name='settings[auto_approve_requests]']"
    assert_select "p", text: /Automatically enqueue search immediately for requests created by non-admin users/
  end

  test "index shows ordered download type preferences" do
    get admin_settings_url

    assert_response :success
    assert_select "input[name='settings[preferred_download_types]'][type='hidden']"
    assert_select "p", text: /Most preferred first/
    assert_select "p", text: "Torrent"
    assert_select "p", text: "Usenet"
    assert_select "p", text: "Direct"
  end

  test "index shows OIDC auto redirect setting" do
    get admin_settings_url

    assert_response :success
    assert_select "label", text: "Oidc Auto Redirect"
    assert_select "input[name='settings[oidc_auto_redirect]']"
    assert_select "p", text: /Use \/session\/new\?local=1/
  end

  test "index shows OIDC link existing users setting" do
    get admin_settings_url

    assert_response :success
    assert_select "label", text: "Oidc Link Existing Users"
    assert_select "input[name='settings[oidc_link_existing_users]']"
    assert_select "p", text: /link an unlinked local user/
  end

  test "bulk_update stores ordered download type preferences" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        preferred_download_types: %w[direct usenet torrent]
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal %w[direct usenet torrent], SettingsService.preferred_download_types
  end

  test "bulk_update stores OIDC auto redirect setting" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        oidc_auto_redirect: "true"
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal true, SettingsService.get(:oidc_auto_redirect)
  end

  test "bulk_update stores OIDC link existing users setting" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        oidc_link_existing_users: "true"
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal true, SettingsService.get(:oidc_link_existing_users)
  end

  test "index shows library picker dropdown when audiobookshelf configured" do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .with(headers: { "Authorization" => "Bearer test-api-key" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "libraries" => [
              { "id" => "lib-audio", "name" => "Audiobooks", "mediaType" => "book", "folders" => [] },
              { "id" => "lib-ebook", "name" => "Ebooks", "mediaType" => "book", "folders" => [] }
            ]
          }.to_json
        )

      get admin_settings_url
      assert_response :success

      # Check that library options appear in the page
      assert_select "select[name='settings[audiobookshelf_audiobook_library_id]']" do
        assert_select "option[value='lib-audio']", text: "Audiobooks (book)"
        assert_select "option[value='lib-ebook']", text: "Ebooks (book)"
      end
    end
  end

  test "index shows text input when audiobookshelf not configured" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobookshelf_api_key, "")

    get admin_settings_url
    assert_response :success

    # Should show text input instead of select
    assert_select "input[name='settings[audiobookshelf_audiobook_library_id]']"
  end

  test "index handles audiobookshelf api errors gracefully" do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .to_return(status: 500)

      # Should not raise, should show text input as fallback
      get admin_settings_url
      assert_response :success
      assert_select "input[name='settings[audiobookshelf_audiobook_library_id]']"
    end
  end

  test "index handles malformed audiobookshelf url gracefully" do
    SettingsService.set(:audiobookshelf_url, "audiobookshelf:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    get admin_settings_url

    assert_response :success
    assert_select "input[name='settings[audiobookshelf_audiobook_library_id]']"
  end

  test "bulk_update updates multiple settings" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        max_retries: "20",
        rate_limit_delay: "5"
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal 20, SettingsService.get(:max_retries)
    assert_equal 5, SettingsService.get(:rate_limit_delay)
  end

  test "bulk_update updates allow user uploads setting" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        allow_user_uploads: "true"
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal true, SettingsService.user_uploads_allowed?
  end

  test "bulk_update updates auto approve requests setting" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        auto_approve_requests: "true"
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal true, SettingsService.auto_approve_requests?
  end

  test "update stores a single setting" do
    patch admin_setting_url("max_retries"), params: {
      setting: { value: "7" }
    }

    assert_redirected_to admin_settings_path
    assert_equal "Setting updated.", flash[:notice]
    assert_equal 7, SettingsService.get(:max_retries)
  end

  test "update rejects invalid single path template" do
    patch admin_setting_url("audiobook_path_template"), params: {
      setting: { value: "{invalid_var}" }
    }

    assert_redirected_to admin_settings_path
    assert flash[:alert].present?
  end

  test "index shows webhook settings" do
    get admin_settings_url

    assert_response :success
    assert_select "label", text: "Webhook Enabled"
    assert_select "input[name='settings[webhook_enabled]']"
    assert_select "input[name='settings[webhook_url]']"
    assert_select "input[name='settings[webhook_events]']"
    assert_select "a", text: "Send Test Webhook"
  end

  test "index shows Discord notification settings" do
    get admin_settings_url

    assert_response :success
    assert_select "label", text: "Discord Enabled"
    assert_select "input[name='settings[discord_enabled]']"
    assert_select "input[type='password'][name='settings[discord_webhook_url]']"
    assert_select "input[name='settings[discord_events]']"
    assert_select "a", text: "Send Test Discord"
  end

  test "index shows z-library settings and test button" do
    get admin_settings_url

    assert_response :success
    assert_select "label", text: "Zlibrary Enabled"
    assert_select "input[name='settings[zlibrary_enabled]']"
    assert_select "input[type='hidden'][name='settings[zlibrary_url]']"
    assert_select "[data-url-list] [data-url-list-list]"
    assert_select "input[type='url'][data-url-list-input]"
    assert_select "button[aria-label='Add Z-Library URL']"
    assert_select "input[name='settings[zlibrary_email]']"
    assert_select "input[name='settings[zlibrary_password]']"
    assert_select "a", text: "Test Z-Library Connection"
  end

  test "index shows LibriVox settings and test button" do
    get admin_settings_url

    assert_response :success
    assert_select "label", text: "Librivox Enabled"
    assert_select "input[name='settings[librivox_enabled]']"
    assert_select "input[name='settings[librivox_url]']"
    assert_select "input[name='settings[librivox_search_limit]']"
    assert_select "a", text: "Test LibriVox Connection"
  end

  test "index shows Project Gutenberg settings and test button" do
    get admin_settings_url

    assert_response :success
    assert_select "label", text: "Gutenberg Enabled"
    assert_select "input[name='settings[gutenberg_enabled]']"
    assert_select "input[name='settings[gutenberg_url]']"
    assert_select "input[name='settings[gutenberg_search_limit]']"
    assert_select "a", text: "Test Project Gutenberg Connection"
  end

  test "index shows Anna's Archive URL list setting" do
    get admin_settings_url

    assert_response :success
    assert_select "label", text: "Anna Archive Url"
    assert_select "input[type='hidden'][name='settings[anna_archive_url]']"
    assert_select "button[aria-label=\"Add Anna's Archive URL\"]"
  end

  test "bulk_update validates path templates" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        audiobook_path_template: "{invalid_var}"
      }
    }

    assert_redirected_to admin_settings_path
    assert flash[:alert].present?
  end

  test "bulk_update validates filename templates" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        audiobook_filename_template: "{invalid_var}"
      }
    }

    assert_redirected_to admin_settings_path
    assert flash[:alert].present?
  end

  test "bulk_update accepts backward-compatible filename template without title" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        audiobook_filename_template: "{author}"
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal "{author}", SettingsService.get(:audiobook_filename_template)
  end

  test "bulk_update rejects invalid series number formatting in filename template" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        audiobook_filename_template: "{seriesNum:abc} - {title}"
      }
    }

    assert_redirected_to admin_settings_path
    assert flash[:alert].present?
  end

  test "bulk_update immediately updates output_paths health when paths are valid" do
    Dir.mktmpdir do |audiobook_dir|
      Dir.mktmpdir do |ebook_dir|
        patch bulk_update_admin_settings_url, params: {
          settings: {
            audiobook_output_path: audiobook_dir,
            ebook_output_path: ebook_dir
          }
        }

        assert_redirected_to admin_settings_path

        health = SystemHealth.for_service("output_paths")
        assert health.healthy?
        assert_includes health.message, "accessible"
      end
    end
  end

  test "bulk_update immediately updates output_paths health with failure reason" do
    Dir.mktmpdir do |audiobook_dir|
      patch bulk_update_admin_settings_url, params: {
        settings: {
          audiobook_output_path: audiobook_dir,
          ebook_output_path: "/definitely/missing/path"
        }
      }

      assert_redirected_to admin_settings_path

      health = SystemHealth.for_service("output_paths")
      assert health.degraded?
      assert_includes health.message, "Ebook path does not exist"
    end
  end

  # Test connection tests for Prowlarr
  test "test_prowlarr fails when not configured" do
    SettingsService.set(:prowlarr_url, "")
    SettingsService.set(:prowlarr_api_key, "")

    post test_prowlarr_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not configured/i, flash[:alert]
  end

  test "test_prowlarr succeeds when connection works" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:9696/api/v1/indexer")
        .with(headers: { "X-Api-Key" => "test-api-key" })
        .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })

      post test_prowlarr_admin_settings_url

      assert_redirected_to admin_settings_path
      assert_match /successful/i, flash[:notice]
    end
  end

  test "test_prowlarr fails when connection fails" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:9696/api/v1/indexer")
        .with(headers: { "X-Api-Key" => "test-api-key" })
        .to_return(status: 401)

      post test_prowlarr_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  test "test_prowlarr handles connection errors" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:9696/api/v1/indexer")
        .to_timeout

      post test_prowlarr_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  test "test_indexer succeeds for jackett when selected" do
    SettingsService.set(:indexer_provider, "jackett")
    SettingsService.set(:jackett_url, "http://localhost:9117")
    SettingsService.set(:jackett_api_key, "jackett-key")

    VCR.turned_off do
      stub_request(:get, %r{localhost:9117/api/v2\.0/indexers/all/results/torznab/api})
        .with(query: hash_including("apikey" => "jackett-key", "t" => "caps"))
        .to_return(status: 200, body: "<caps />", headers: { "Content-Type" => "application/xml" })

      post test_indexer_admin_settings_url

      assert_redirected_to admin_settings_path
      assert_match /successful/i, flash[:notice]
    end
  end

  test "test_webhook fails when disabled" do
    SettingsService.set(:webhook_enabled, false)
    SettingsService.set(:webhook_url, "http://localhost:4567/webhook")

    post test_webhook_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not enabled/i, flash[:alert]
  end

  test "test_webhook succeeds when webhook accepts payload" do
    SettingsService.set(:webhook_enabled, true)
    SettingsService.set(:webhook_url, "http://localhost:4567/webhook")
    SettingsService.set(:webhook_token, "secret-token")

    VCR.turned_off do
      stub_request(:post, "http://localhost:4567/webhook")
        .with(
          headers: {
            "Authorization" => "Bearer secret-token",
            "Content-Type" => "application/json",
            "X-Shelfarr-Event" => "test"
          }
        )
        .to_return(status: 200, body: "{\"ok\":true}", headers: { "Content-Type" => "application/json" })

      post test_webhook_admin_settings_url

      assert_redirected_to admin_settings_path
      assert_match /successfully/i, flash[:notice]
    end
  end

  test "test_webhook handles invalid webhook URL" do
    SettingsService.set(:webhook_enabled, true)
    SettingsService.set(:webhook_url, "ht!tp://bad")

    post test_webhook_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /invalid/i, flash[:alert]
  end

  test "test_discord fails when disabled" do
    SettingsService.set(:discord_enabled, false)
    SettingsService.set(:discord_webhook_url, "https://discord.com/api/webhooks/123/token")

    post test_discord_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not enabled/i, flash[:alert]
  end

  test "test_discord succeeds when Discord accepts payload" do
    SettingsService.set(:discord_enabled, true)
    SettingsService.set(:discord_webhook_url, "https://discord.com/api/webhooks/123/token")

    VCR.turned_off do
      stub_request(:post, "https://discord.com/api/webhooks/123/token?wait=true")
        .with do |request|
          json = JSON.parse(request.body)
          json["username"] == "Shelfarr" &&
            json["allowed_mentions"] == { "parse" => [] } &&
            json["embeds"].first["title"] == "Shelfarr Test"
        end
        .to_return(status: 200, body: { id: "message-id" }.to_json, headers: { "Content-Type" => "application/json" })

      post test_discord_admin_settings_url

      assert_redirected_to admin_settings_path
      assert_match /successfully/i, flash[:notice]
    end
  end

  test "test_discord handles invalid webhook URL" do
    SettingsService.set(:discord_enabled, true)
    SettingsService.set(:discord_webhook_url, "ht!tp://bad")

    post test_discord_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /invalid/i, flash[:alert]
  end

  test "test_telegram succeeds when bot token works" do
    SettingsService.set(:telegram_enabled, true)
    SettingsService.set(:telegram_bot_token, "telegram-token")
    SettingsService.set(:telegram_webhook_secret, "telegram-secret")

    VCR.turned_off do
      stub_request(:post, "https://api.telegram.org/bottelegram-token/getMe")
        .to_return(
          status: 200,
          body: { ok: true, result: { username: "ShelfarrBot" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      post test_telegram_admin_settings_url

      assert_redirected_to admin_settings_path
      assert_match /@ShelfarrBot/, flash[:notice]
    end
  end

  test "test_telegram fails when not configured" do
    SettingsService.set(:telegram_enabled, false)
    SettingsService.set(:telegram_bot_token, "")
    SettingsService.set(:telegram_webhook_secret, "")

    post test_telegram_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not fully configured/i, flash[:alert]
  end

  test "test_telegram reports client errors" do
    SettingsService.set(:telegram_enabled, true)
    SettingsService.set(:telegram_bot_token, "telegram-token")
    SettingsService.set(:telegram_webhook_secret, "telegram-secret")

    Integrations::Telegram::Client.stub(:get_me, -> { raise Integrations::Telegram::Client::DeliveryError, "boom" }) do
      post test_telegram_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_equal "boom", flash[:alert]
  end

  test "setup_telegram_webhook registers webhook URL" do
    SettingsService.set(:telegram_enabled, true)
    SettingsService.set(:telegram_update_mode, "polling")
    SettingsService.set(:telegram_bot_token, "telegram-token")
    SettingsService.set(:telegram_webhook_secret, "telegram-secret")

    VCR.turned_off do
      stub = stub_request(:post, "https://api.telegram.org/bottelegram-token/setWebhook")
        .with do |request|
          body = JSON.parse(request.body)
          body["url"].include?("/integrations/telegram/webhook") &&
            body["secret_token"] == "telegram-secret"
        end
        .to_return(
          status: 200,
          body: { ok: true, result: true }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      post setup_telegram_webhook_admin_settings_url

      assert_redirected_to admin_settings_path
      assert_match /webhook configured/i, flash[:notice]
      assert_equal "webhook", SettingsService.get(:telegram_update_mode)
      assert_requested stub
    end
  end

  test "setup_telegram_webhook fails when not configured" do
    SettingsService.set(:telegram_enabled, false)
    SettingsService.set(:telegram_bot_token, "")
    SettingsService.set(:telegram_webhook_secret, "")

    post setup_telegram_webhook_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not fully configured/i, flash[:alert]
  end

  test "setup_telegram_webhook reports client errors" do
    SettingsService.set(:telegram_enabled, true)
    SettingsService.set(:telegram_bot_token, "telegram-token")
    SettingsService.set(:telegram_webhook_secret, "telegram-secret")

    Integrations::Telegram::Client.stub(:set_webhook!, ->(url:) { raise Integrations::Telegram::Client::DeliveryError, "webhook boom" }) do
      post setup_telegram_webhook_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_equal "webhook boom", flash[:alert]
  end

  test "approve_telegram_chat approves a pending group code" do
    authorization, code = TelegramChatAuthorization.issue!(
      chat_id: "-100123",
      chat_title: "Readers",
      requested_by_telegram_user_id: "42",
      requested_by_telegram_username: "telegramuser"
    )

    post approve_telegram_chat_admin_settings_url, params: { telegram_group_code: code }

    assert_redirected_to admin_settings_path
    assert_match /Telegram group authorized: Readers/, flash[:notice]
    assert authorization.reload.approved?
    assert_equal @admin, authorization.approved_by
  end

  test "approve_telegram_chat rejects invalid or expired code" do
    post approve_telegram_chat_admin_settings_url, params: { telegram_group_code: "000000" }

    assert_redirected_to admin_settings_path
    assert_match /invalid or expired/i, flash[:alert]
  end

  test "pause_telegram_chat pauses an approved group" do
    authorization = TelegramChatAuthorization.create!(
      chat_id: "-100123",
      chat_title: "Readers",
      approved_at: Time.current,
      approved_by: @admin
    )

    post pause_telegram_chat_admin_settings_url(authorization)

    assert_redirected_to admin_settings_path
    assert_match /Telegram group paused: Readers/, flash[:notice]
    assert authorization.reload.paused?
  end

  test "resume_telegram_chat resumes a paused group" do
    authorization = TelegramChatAuthorization.create!(
      chat_id: "-100123",
      chat_title: "Readers",
      approved_at: Time.current,
      approved_by: @admin,
      paused_at: Time.current
    )

    post resume_telegram_chat_admin_settings_url(authorization)

    assert_redirected_to admin_settings_path
    assert_match /Telegram group resumed: Readers/, flash[:notice]
    assert_not authorization.reload.paused?
  end

  test "delete_telegram_chat removes a group authorization" do
    authorization = TelegramChatAuthorization.create!(
      chat_id: "-100123",
      chat_title: "Readers",
      approved_at: Time.current,
      approved_by: @admin
    )

    assert_difference "TelegramChatAuthorization.count", -1 do
      delete delete_telegram_chat_admin_settings_url(authorization)
    end

    assert_redirected_to admin_settings_path
    assert_match /Telegram group removed: Readers/, flash[:notice]
  end

  test "test_zlibrary fails when not configured" do
    SettingsService.set(:zlibrary_enabled, false)
    SettingsService.set(:zlibrary_url, "")
    SettingsService.set(:zlibrary_email, "")
    SettingsService.set(:zlibrary_password, "")

    post test_zlibrary_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not configured/i, flash[:alert]
  end

  test "test_zlibrary succeeds when connection works" do
    SettingsService.set(:zlibrary_enabled, true)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "reader@example.com")
    SettingsService.set(:zlibrary_password, "secret")

    ZLibraryClient.stub :test_connection, true do
      post test_zlibrary_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /successful/i, flash[:notice]
  end

  test "test_zlibrary fails when connection fails" do
    SettingsService.set(:zlibrary_enabled, true)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "reader@example.com")
    SettingsService.set(:zlibrary_password, "secret")

    ZLibraryClient.stub :test_connection, false do
      post test_zlibrary_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /failed/i, flash[:alert]
  end

  test "test_librivox fails when disabled" do
    SettingsService.set(:librivox_enabled, false)

    post test_librivox_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not enabled/i, flash[:alert]
  end

  test "test_librivox succeeds when connection works" do
    SettingsService.set(:librivox_enabled, true)

    LibrivoxClient.stub :test_connection, true do
      post test_librivox_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /successful/i, flash[:notice]
  end

  test "test_librivox fails when connection fails" do
    SettingsService.set(:librivox_enabled, true)

    LibrivoxClient.stub :test_connection, false do
      post test_librivox_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /failed/i, flash[:alert]
  end

  test "test_gutenberg fails when disabled" do
    SettingsService.set(:gutenberg_enabled, false)

    post test_gutenberg_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not enabled/i, flash[:alert]
  end

  test "test_gutenberg succeeds when connection works" do
    SettingsService.set(:gutenberg_enabled, true)

    GutenbergClient.stub :test_connection, true do
      post test_gutenberg_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /successful/i, flash[:notice]
  end

  test "test_gutenberg fails when connection fails" do
    SettingsService.set(:gutenberg_enabled, true)

    GutenbergClient.stub :test_connection, false do
      post test_gutenberg_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /failed/i, flash[:alert]
  end

  # Test connection tests for Audiobookshelf
  test "test_audiobookshelf fails when not configured" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobookshelf_api_key, "")

    post test_audiobookshelf_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not configured/i, flash[:alert]
  end

  test "test_audiobookshelf succeeds when connection works" do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .with(headers: { "Authorization" => "Bearer test-api-key" })
        .to_return(
          status: 200,
          body: { "libraries" => [ { "id" => "lib1", "name" => "Test" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      post test_audiobookshelf_admin_settings_url

      assert_redirected_to admin_settings_path
      assert_match /successful/i, flash[:notice]
    end
  end

  test "test_audiobookshelf fails when connection fails" do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .with(headers: { "Authorization" => "Bearer test-api-key" })
        .to_return(status: 401)

      post test_audiobookshelf_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  test "test_audiobookshelf handles connection errors" do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .to_timeout

      post test_audiobookshelf_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  test "test_audiobookshelf reports client errors" do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    AudiobookshelfClient.stub(:test_connection, -> { raise AudiobookshelfClient::Error, "abs boom" }) do
      post test_audiobookshelf_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /abs boom/, flash[:alert]
  end

  test "test_audiobookshelf handles malformed urls" do
    SettingsService.set(:audiobookshelf_url, "audiobookshelf:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    post test_audiobookshelf_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match(/failed/i, flash[:alert])
  end

  test "sync_audiobookshelf_library fails when not configured" do
    SettingsService.set(:audiobookshelf_url, "")
    SettingsService.set(:audiobookshelf_api_key, "")

    post sync_audiobookshelf_library_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not configured/i, flash[:alert]
  end

  test "sync_audiobookshelf_library enqueues a sync job" do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    assert_enqueued_with(job: AudiobookshelfLibrarySyncJob) do
      post sync_audiobookshelf_library_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /sync started/i, flash[:notice]
  end

  # Test connection tests for OIDC
  test "test_oidc fails when not enabled" do
    SettingsService.set(:oidc_enabled, false)

    post test_oidc_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not enabled/i, flash[:alert]
  end

  test "test_oidc fails when issuer not configured" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "")

    post test_oidc_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not configured/i, flash[:alert]
  end

  test "test_oidc succeeds when discovery document valid" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "test-client")
    SettingsService.set(:oidc_client_secret, "test-secret")

    VCR.turned_off do
      stub_request(:get, "https://auth.example.com/.well-known/openid-configuration")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            issuer: "https://auth.example.com",
            authorization_endpoint: "https://auth.example.com/authorize",
            token_endpoint: "https://auth.example.com/token"
          }.to_json
        )

      post test_oidc_admin_settings_url

      assert_redirected_to admin_settings_path
      assert_match /valid/i, flash[:notice]
    end
  end

  test "test_oidc fails when discovery document invalid" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "test-client")
    SettingsService.set(:oidc_client_secret, "test-secret")

    VCR.turned_off do
      stub_request(:get, "https://auth.example.com/.well-known/openid-configuration")
        .to_return(status: 404)

      post test_oidc_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  test "test_oidc fails when discovery document is incomplete" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")

    VCR.turned_off do
      stub_request(:get, "https://auth.example.com/.well-known/openid-configuration")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { issuer: "https://auth.example.com" }.to_json
        )

      post test_oidc_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /incomplete/i, flash[:alert]
  end

  test "test_oidc fails when discovery document is not json" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")

    VCR.turned_off do
      stub_request(:get, "https://auth.example.com/.well-known/openid-configuration")
        .to_return(status: 200, body: "not-json")

      post test_oidc_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /not valid JSON/i, flash[:alert]
  end

  test "test_oidc handles connection errors" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "test-client")
    SettingsService.set(:oidc_client_secret, "test-secret")

    VCR.turned_off do
      stub_request(:get, "https://auth.example.com/.well-known/openid-configuration")
        .to_timeout

      post test_oidc_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  # Turbo Stream response tests
  test "bulk_update returns turbo stream when requested" do
    patch bulk_update_admin_settings_url,
      params: { settings: { max_retries: "25" } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match "turbo-stream", response.body
    assert_match "settings-form", response.body
    assert_equal 25, SettingsService.get(:max_retries)
  end

  test "bulk_update turbo stream shows error on validation failure" do
    patch bulk_update_admin_settings_url,
      params: { settings: { audiobook_path_template: "{invalid_var}" } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match "turbo-stream", response.body
    assert_match "flash", response.body
  end

  test "bulk_update accepts optional template syntax for filename templates" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        audiobook_filename_template: "{author} - {series - }{title}"
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal "{author} - {series - }{title}", SettingsService.get(:audiobook_filename_template)
  end

  test "test_prowlarr returns turbo stream when requested" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:9696/api/v1/indexer")
        .with(headers: { "X-Api-Key" => "test-api-key" })
        .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })

      post test_prowlarr_admin_settings_url,
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      assert_match "turbo-stream", response.body
    end
  end

  test "test_audiobookshelf returns turbo stream when requested" do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:13378/api/libraries")
        .with(headers: { "Authorization" => "Bearer test-api-key" })
        .to_return(
          status: 200,
          body: { "libraries" => [ { "id" => "lib1", "name" => "Test" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      post test_audiobookshelf_admin_settings_url,
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      assert_match "turbo-stream", response.body
    end
  end

  # SSL error handling tests
  test "test_prowlarr handles SSL errors" do
    SettingsService.set(:prowlarr_url, "https://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "https://localhost:9696/api/v1/indexer")
        .to_raise(Faraday::SSLError.new("SSL certificate verify failed"))

      post test_prowlarr_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  test "test_audiobookshelf handles SSL errors" do
    SettingsService.set(:audiobookshelf_url, "https://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    VCR.turned_off do
      stub_request(:get, "https://localhost:13378/api/libraries")
        .to_raise(Faraday::SSLError.new("SSL certificate verify failed"))

      post test_audiobookshelf_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  test "test_oidc handles SSL errors" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")
    SettingsService.set(:oidc_client_id, "test-client")
    SettingsService.set(:oidc_client_secret, "test-secret")

    VCR.turned_off do
      stub_request(:get, "https://auth.example.com/.well-known/openid-configuration")
        .to_raise(Faraday::SSLError.new("SSL certificate verify failed"))

      post test_oidc_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end
  end

  test "test_oidc reports generic errors" do
    SettingsService.set(:oidc_enabled, true)
    SettingsService.set(:oidc_issuer, "https://auth.example.com")

    VCR.turned_off do
      stub_request(:get, "https://auth.example.com/.well-known/openid-configuration")
        .to_raise(StandardError.new("unexpected"))

      post test_oidc_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /unexpected/, flash[:alert]
  end

  # Connection cache reset tests
  test "bulk_update uses new audiobookshelf url after settings change" do
    SettingsService.set(:audiobookshelf_url, "http://old.example.com")
    SettingsService.set(:audiobookshelf_api_key, "test-key")

    VCR.turned_off do
      # The controller should use the NEW url after updating settings
      # This verifies the connection was reset and recreated with new credentials
      stub_request(:get, "http://new.example.com/api/libraries")
        .to_return(status: 200, body: { "libraries" => [] }.to_json, headers: { "Content-Type" => "application/json" })

      patch bulk_update_admin_settings_url, params: {
        settings: { audiobookshelf_url: "http://new.example.com" }
      }

      assert_response :redirect
      assert_equal "http://new.example.com", SettingsService.get(:audiobookshelf_url)
      # If reset didn't work, it would have tried old.example.com and failed
      assert_requested(:get, "http://new.example.com/api/libraries")
    end
  end

  test "bulk_update resets prowlarr connection when api key changes" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "old-key")

    # Prime the connection with old credentials
    ProwlarrClient.send(:connection)
    old_connection = ProwlarrClient.instance_variable_get(:@connection)
    assert_not_nil old_connection

    patch bulk_update_admin_settings_url, params: {
      settings: { prowlarr_api_key: "new-key" }
    }

    # Connection should be reset - either nil or a different object
    new_connection = ProwlarrClient.instance_variable_get(:@connection)
    assert_nil new_connection, "Connection should be reset after prowlarr settings change"
  end

  # Test connection tests for FlareSolverr
  test "test_flaresolverr fails when not configured" do
    SettingsService.set(:flaresolverr_url, "")

    post test_flaresolverr_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not configured/i, flash[:alert]
  end

  test "test_flaresolverr succeeds when connection works" do
    SettingsService.set(:flaresolverr_url, "http://localhost:8191")

    VCR.turned_off do
      stub_request(:post, "http://localhost:8191/v1")
        .to_return(
          status: 200,
          body: {
            status: "ok",
            message: "",
            solution: { status: 200, response: "<html></html>" }
          }.to_json
        )

      post test_flaresolverr_admin_settings_url

      assert_redirected_to admin_settings_path
      assert_match /successful/i, flash[:notice]
    end

    FlaresolverrClient.reset_connection!
    SettingsService.set(:flaresolverr_url, "")
  end

  test "test_flaresolverr fails when connection fails" do
    SettingsService.set(:flaresolverr_url, "http://localhost:8191")

    VCR.turned_off do
      stub_request(:post, "http://localhost:8191/v1")
        .to_return(
          status: 200,
          body: { status: "error", message: "Challenge failed" }.to_json
        )

      post test_flaresolverr_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end

    FlaresolverrClient.reset_connection!
    SettingsService.set(:flaresolverr_url, "")
  end

  test "test_flaresolverr handles connection errors" do
    SettingsService.set(:flaresolverr_url, "http://localhost:8191")

    VCR.turned_off do
      stub_request(:post, "http://localhost:8191/v1")
        .to_raise(Faraday::ConnectionFailed.new("Connection refused"))

      post test_flaresolverr_admin_settings_url

      assert_redirected_to admin_settings_path
      assert flash[:alert].present?
    end

    FlaresolverrClient.reset_connection!
    SettingsService.set(:flaresolverr_url, "")
  end

  test "test_flaresolverr reports client errors" do
    SettingsService.set(:flaresolverr_url, "http://localhost:8191")

    FlaresolverrClient.stub(:test_connection, -> { raise FlaresolverrClient::Error, "flare boom" }) do
      post test_flaresolverr_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /flare boom/, flash[:alert]
  end

  test "test_hardcover fails when not configured" do
    SettingsService.set(:hardcover_api_token, "")

    post test_hardcover_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not configured/i, flash[:alert]
  end

  test "test_hardcover succeeds when connection works" do
    SettingsService.set(:hardcover_api_token, "token")

    HardcoverClient.stub(:test_connection, true) do
      post test_hardcover_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /successful/i, flash[:notice]
  end

  test "test_hardcover fails when connection fails" do
    SettingsService.set(:hardcover_api_token, "token")

    HardcoverClient.stub(:test_connection, false) do
      post test_hardcover_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /failed/i, flash[:alert]
  end

  test "test_hardcover reports client errors" do
    SettingsService.set(:hardcover_api_token, "token")

    HardcoverClient.stub(:test_connection, -> { raise HardcoverClient::Error, "hard boom" }) do
      post test_hardcover_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /hard boom/, flash[:alert]
  end

  test "test_flaresolverr returns turbo stream when requested" do
    SettingsService.set(:flaresolverr_url, "http://localhost:8191")

    VCR.turned_off do
      stub_request(:post, "http://localhost:8191/v1")
        .to_return(
          status: 200,
          body: {
            status: "ok",
            message: "",
            solution: { status: 200, response: "<html></html>" }
          }.to_json
        )

      post test_flaresolverr_admin_settings_url,
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      assert_match "turbo-stream", response.body
    end

    FlaresolverrClient.reset_connection!
    SettingsService.set(:flaresolverr_url, "")
  end

  test "bulk_update resets flaresolverr connection when url changes" do
    SettingsService.set(:flaresolverr_url, "http://old.example.com:8191")

    # Prime the connection with old url
    FlaresolverrClient.send(:connection)
    old_connection = FlaresolverrClient.instance_variable_get(:@connection)
    assert_not_nil old_connection

    patch bulk_update_admin_settings_url, params: {
      settings: { flaresolverr_url: "http://new.example.com:8191" }
    }

    # Connection should be reset
    new_connection = FlaresolverrClient.instance_variable_get(:@connection)
    assert_nil new_connection, "Connection should be reset after flaresolverr settings change"

    SettingsService.set(:flaresolverr_url, "")
  end
end
