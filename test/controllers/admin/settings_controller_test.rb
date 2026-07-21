# frozen_string_literal: true

require "test_helper"

class Admin::SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    clear_settings_env!
    @admin = users(:two)
    sign_in_as(@admin)
    LibraryPlatformClient.reset_connections!
    ProwlarrClient.reset_connection!
    FlaresolverrClient.reset_connection!
    GoogleBooksClient.reset_connection!
    OpenLibraryClient.reset_connection!
    ZLibraryClient.reset_connection! if defined?(ZLibraryClient)
    EbooksComClient.reset_connection! if defined?(EbooksComClient)
    SettingsService.set(:ebooks_com_enabled, false)
    SettingsService.set(:ebooks_com_country_code, "")
  end

  teardown do
    restore_settings_env!
    LibraryPlatformClient.reset_connections!
    ProwlarrClient.reset_connection!
    FlaresolverrClient.reset_connection!
    GoogleBooksClient.reset_connection!
    OpenLibraryClient.reset_connection!
    ZLibraryClient.reset_connection! if defined?(ZLibraryClient)
    EbooksComClient.reset_connection! if defined?(EbooksComClient)
    SettingsService.set(:ebooks_com_enabled, false)
    SettingsService.set(:ebooks_com_country_code, "")
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
    assert_select "#settings-tabs noscript", text: /Use Save All/
    assert_select "#settings-tabs noscript style", count: 0
    assert_select "#settings-tabs [data-settings-tabs-target='tablist'].hidden [role='tablist']", count: 1
  end

  test "index shows telegram group authorization only in integrations tab" do
    get admin_settings_url

    assert_response :success
    assert_select "[data-settings-tabs-target='panel'][data-tab='integrations'] h2",
      text: "Telegram Group Authorization",
      count: 1
    %w[search downloads system security].each do |tab|
      assert_select "[data-settings-tabs-target='panel'][data-tab='#{tab}'] h2",
        text: "Telegram Group Authorization",
        count: 0
    end
  end

  test "index shows indexer provider dropdown" do
    SettingsService.set(:indexer_provider, "prowlarr")
    SettingsService.set(:prowlarr_api_key, "stored-prowlarr-secret")

    get admin_settings_url

    assert_response :success
    assert_select "select[name='settings[indexer_provider]']"
    assert_select "option[value='prowlarr']", text: "Prowlarr"
    assert_select "option[value='jackett']", text: "Jackett"
    assert_select "option[value='newznab']", text: "NZBHydra2 / Newznab"
    assert_select "input[type='url'][name='settings[prowlarr_url]']:not([disabled])"
    assert_select "input[type='url'][name='settings[jackett_url]'][disabled]"
    assert_select "input[type='url'][name='settings[newznab_url]'][disabled]"
    assert_select "input[name='settings[newznab_api_key]']"
    assert_select "input[type='password'][name='settings[prowlarr_api_key]'][value='']"
    assert_no_match /stored-prowlarr-secret/, @response.body
  end

  test "index shows metadata provider test buttons and options" do
    get admin_settings_url

    assert_response :success
    assert_select "a[href='#{test_google_books_admin_settings_path}']", text: "Test Google Books Connection"
    assert_select "a[href='#{test_open_library_admin_settings_path}']", text: "Test Open Library Connection"
    assert_select "a[href='#{test_comic_vine_admin_settings_path}']", text: "Test Comic Vine Connection"
    assert_select "select[name='settings[metadata_source]'] option[value='comic_vine']", text: "Comic Vine"
  end

  test "index shows beta eBooks.com store settings" do
    get admin_settings_url

    assert_response :success
    assert_select "h2", text: "eBooks.com Store (Beta)"
    assert_select "input[name='settings[ebooks_com_enabled]']"
    assert_select "input[name='settings[ebooks_com_country_code]'][maxlength='2'][pattern='[A-Za-z]{2}'][autocapitalize='characters']"
    assert_select "input[name='settings[ebooks_com_search_limit]'][min='1'][max='#{EbooksComClient::MAX_RESULTS}']"
    assert_select "button[formaction='#{test_ebooks_com_admin_settings_path}'][formmethod='post']", text: "Test eBooks.com Catalog"
  end

  test "bulk_update rejects an invalid eBooks.com country and missing enabled country" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        ebooks_com_enabled: "1",
        ebooks_com_country_code: "Portugal",
        ebooks_com_search_limit: "5"
      }
    }

    assert_redirected_to admin_settings_path
    assert_match(/ISO 3166-1/i, flash[:alert])
    assert_not SettingsService.get(:ebooks_com_enabled)
    assert_equal "", SettingsService.get(:ebooks_com_country_code)

    patch bulk_update_admin_settings_url, params: {
      settings: {
        ebooks_com_enabled: "1",
        ebooks_com_country_code: "",
        ebooks_com_search_limit: "5"
      }
    }

    assert_redirected_to admin_settings_path
    assert_match(/Buyer Country Code/i, flash[:alert])
    assert_not SettingsService.get(:ebooks_com_enabled)
  end

  test "bulk_update normalizes a valid eBooks.com country and validates the offer limit" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        ebooks_com_enabled: "1",
        ebooks_com_country_code: " pt ",
        ebooks_com_search_limit: "3"
      }
    }, headers: { "HTTP_REFERER" => "https://attacker.example/phishing" }

    assert_redirected_to admin_settings_path
    assert flash[:alert].blank?
    assert SettingsService.get(:ebooks_com_enabled)
    assert_equal "PT", SettingsService.get(:ebooks_com_country_code)
    assert_equal 3, SettingsService.get(:ebooks_com_search_limit)

    patch bulk_update_admin_settings_url, params: {
      settings: { ebooks_com_search_limit: "3-results" }
    }

    assert_redirected_to admin_settings_path
    assert_match(/between 1 and #{EbooksComClient::MAX_RESULTS}/, flash[:alert])
    assert_equal 3, SettingsService.get(:ebooks_com_search_limit)

    patch bulk_update_admin_settings_url, params: {
      settings: { ebooks_com_search_limit: (EbooksComClient::MAX_RESULTS + 1).to_s }
    }

    assert_redirected_to admin_settings_path
    assert_match(/between 1 and #{EbooksComClient::MAX_RESULTS}/, flash[:alert])
    assert_equal 3, SettingsService.get(:ebooks_com_search_limit)
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

  test "index shows split audiobook bundle imports setting" do
    get admin_settings_url

    assert_response :success
    assert_select "label", text: "Split Audiobook Bundle Imports"
    assert_select "input[name='settings[split_audiobook_bundle_imports]']"
    assert_select "p", text: /MP3, FLAC, and other chapter-based releases stay together/
  end

  test "index shows completed download import mode options and hardlink guidance" do
    SettingsService.set(:completed_download_import_mode, "hardlink")

    get admin_settings_url

    assert_response :success
    assert_select "label[for='settings_completed_download_import_mode']", text: "Completed Download Import Mode"
    assert_select "select[name='settings[completed_download_import_mode]']" do
      assert_select "option[value='copy']", text: "Copy"
      assert_select "option[value='move']", text: "Move"
      assert_select "option[value='hardlink'][selected='selected']", text: "Hardlink"
    end
    assert_select "p", text: /Copy: Retains the source and uses extra disk space/
    assert_select "p", text: /Move: Removes the source and can stop torrent seeding/
    assert_select "p", text: /Hardlink: Retains the source without duplicate data; unsupported or cross-filesystem links fall back to copy/
    assert_select "p", text: /Hardlinked names share content, ownership, and permissions; edits through either name affect both/
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

  test "bulk_update stores split audiobook bundle imports setting" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        split_audiobook_bundle_imports: "true"
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal true, SettingsService.get(:split_audiobook_bundle_imports)
  end

  test "bulk_update stores a valid completed download import mode" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        completed_download_import_mode: "hardlink"
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal "hardlink", SettingsService.get(:completed_download_import_mode)
  end

  test "bulk_update rejects an invalid completed download import mode" do
    SettingsService.set(:completed_download_import_mode, "move")

    patch bulk_update_admin_settings_url, params: {
      settings: {
        completed_download_import_mode: "rename"
      }
    }

    assert_redirected_to admin_settings_path
    assert_match /must be one of: copy, move, hardlink/, flash[:alert]
    assert_equal "move", SettingsService.get(:completed_download_import_mode)
  end

  test "bulk_update collects an invalid import mode while saving valid settings and running side effects" do
    reset_called = false

    FlaresolverrClient.stub(:reset_connection!, -> { reset_called = true }) do
      patch bulk_update_admin_settings_url,
        params: {
          settings: {
            completed_download_import_mode: "rename",
            flaresolverr_url: "http://localhost:8191"
          }
        },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_match "turbo-stream", response.body
    assert_match "Completed Download Import Mode: must be one of: copy, move, hardlink", response.body
    assert_equal "copy", SettingsService.get(:completed_download_import_mode)
    assert_equal "http://localhost:8191", SettingsService.get(:flaresolverr_url)
    assert reset_called
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
      assert_select "select[name='settings[audiobookshelf_comicbook_library_id]']"
    end
  end

  test "index renders additional scan libraries as a multi-select when audiobookshelf configured" do
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")
    SettingsService.set(:audiobookshelf_audiobook_scan_library_ids, "lib-audio")

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

      # Check that library options appear in the page as a multi-select
      assert_select "select[name='settings[audiobookshelf_audiobook_scan_library_ids][]'][multiple]" do
        assert_select "option[value='lib-audio'][selected]", text: "Audiobooks (book)"
        assert_select "option[value='lib-ebook']", text: "Ebooks (book)"
      end
    end
  end

  test "index shows neutral and brand-correct library platform labels" do
    get admin_settings_url

    assert_response :success
    assert_select "label[for='settings_library_platform']", text: "Active Library Platform"
    assert_select "label[for='settings_audiobookshelf_url']", text: "Audiobookshelf URL"
    assert_select "label[for='settings_audiobookshelf_api_key']", text: "Audiobookshelf API Key"
    assert_select "label[for='settings_bookorbit_url']", text: "BookOrbit URL"
    assert_select "label[for='settings_bookorbit_username']", text: "BookOrbit Username"
    assert_select "label[for='settings_bookorbit_password']", text: "BookOrbit Password"
    assert_select "label[for='settings_grimmory_url']", text: "Grimmory URL"
    assert_select "label[for='settings_grimmory_username']", text: "Grimmory Username"
    assert_select "label[for='settings_grimmory_password']", text: "Grimmory Password"
    assert_select "label[for='settings_audiobookshelf_audiobook_library_id']", text: "Audiobook Library"
    assert_select "label[for='settings_audiobookshelf_ebook_library_id']", text: "Ebook Library"
    assert_select "label[for='settings_audiobookshelf_comicbook_library_id']", text: "Comics & Manga Library"
    assert_select "label[for='settings_audiobookshelf_audiobook_scan_library_ids']", text: "Additional Audiobook Libraries to Scan"
    assert_select "label[for='settings_audiobookshelf_ebook_scan_library_ids']", text: "Additional Ebook Libraries to Scan"
    assert_select "label[for='settings_audiobookshelf_comicbook_scan_library_ids']", text: "Additional Comics & Manga Libraries to Scan"
    assert_select "label[for='settings_audiobookshelf_library_sync_interval']", text: "Library Sync Interval"
    assert_no_match /Bookorbit/, @response.body
    assert_no_match /Audiobookshelf Audiobook Library/, @response.body
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

  test "bulk_update preserves existing secret settings when left blank" do
    SettingsService.set(:grimmory_password, "existing-secret")
    SettingsService.set(:discord_webhook_url, "https://discord.com/api/webhooks/existing")

    patch bulk_update_admin_settings_url, params: {
      settings: {
        grimmory_password: "",
        discord_webhook_url: ""
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal "existing-secret", SettingsService.get(:grimmory_password)
    assert_equal "https://discord.com/api/webhooks/existing", SettingsService.get(:discord_webhook_url)
  end

  test "bulk_update skips side effects when preserving blank secret settings" do
    SettingsService.set(:library_platform, "grimmory")
    SettingsService.set(:grimmory_url, "http://localhost:5173")
    SettingsService.set(:grimmory_username, "admin")
    SettingsService.set(:grimmory_password, "existing-secret")

    reset_called = false
    sync_called = false

    LibraryPlatformClient.stub(:reset_connections!, -> { reset_called = true }) do
      AudiobookshelfLibrarySyncJob.stub(:perform_later, -> { sync_called = true }) do
        patch bulk_update_admin_settings_url, params: {
          settings: {
            grimmory_password: ""
          }
        }
      end
    end

    assert_redirected_to admin_settings_path
    assert_equal "existing-secret", SettingsService.get(:grimmory_password)
    assert_not reset_called
    assert_not sync_called
  end

  test "index does not render saved secret setting values" do
    SettingsService.set(:grimmory_password, "existing-secret")
    SettingsService.set(:discord_webhook_url, "https://discord.com/api/webhooks/existing")

    get admin_settings_url

    assert_response :success
    assert_select "input[type='password'][name='settings[grimmory_password]'][value='']"
    assert_select "input[type='password'][name='settings[discord_webhook_url]'][value='']"
    assert_no_match "existing-secret", response.body
    assert_no_match "https://discord.com/api/webhooks/existing", response.body
  end

  test "index renders env managed settings as read-only and masks secret values" do
    SettingsService.set(:oidc_client_secret, "stored-secret")

    with_env("SHELFARR_SETTING_OIDC_CLIENT_SECRET" => "env-secret") do
      get admin_settings_url

      assert_response :success
      assert_select "input[name='settings[oidc_client_secret]']", count: 0
      assert_select "[title='Managed by SHELFARR_SETTING_OIDC_CLIENT_SECRET']"
      assert_select "code", text: "SHELFARR_SETTING_OIDC_CLIENT_SECRET"
      assert_match "********", response.body
      assert_no_match "env-secret", response.body
      assert_no_match "stored-secret", response.body
    end
  end

  test "update stores a single setting" do
    patch admin_setting_url("max_retries"), params: {
      setting: { value: "7" }
    }

    assert_redirected_to admin_settings_path
    assert_equal "Setting updated.", flash[:notice]
    assert_equal 7, SettingsService.get(:max_retries)
  end

  test "bulk update joins scan library ids array into comma-separated string" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        audiobookshelf_audiobook_scan_library_ids: [ "lib-scifi", "lib-fantasy", "" ]
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal "lib-scifi,lib-fantasy", SettingsService.get(:audiobookshelf_audiobook_scan_library_ids)
  end

  test "bulk update accepts comma-separated string for scan library ids" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        audiobookshelf_ebook_scan_library_ids: "lib-a, lib-b ,lib-c"
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal "lib-a,lib-b,lib-c", SettingsService.get(:audiobookshelf_ebook_scan_library_ids)
  end

  test "update preserves existing secret when blank secret value submitted" do
    SettingsService.set(:prowlarr_api_key, "existing-secret")

    patch admin_setting_url("prowlarr_api_key"), params: {
      setting: { value: "" }
    }

    assert_redirected_to admin_settings_path
    assert_equal "existing-secret", SettingsService.get(:prowlarr_api_key)
  end

  test "update refuses to persist env managed setting" do
    SettingsService.set(:oidc_client_secret, "stored-secret")

    with_env("SHELFARR_SETTING_OIDC_CLIENT_SECRET" => "env-secret") do
      patch admin_setting_url("oidc_client_secret"), params: {
        setting: { value: "attempted-secret" }
      }

      assert_redirected_to admin_settings_path
      assert_match /managed by the environment/, flash[:alert]
      assert_equal "stored-secret", Setting.find_by(key: "oidc_client_secret").typed_value
      assert_equal "env-secret", SettingsService.get(:oidc_client_secret)
    end
  end

  test "bulk_update preserves existing secrets when blank secret values submitted" do
    SettingsService.set(:prowlarr_api_key, "existing-prowlarr-secret")
    SettingsService.set(:discord_webhook_url, "https://discord.com/api/webhooks/123/token")

    patch bulk_update_admin_settings_url, params: {
      settings: {
        prowlarr_api_key: "",
        discord_webhook_url: ""
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal "existing-prowlarr-secret", SettingsService.get(:prowlarr_api_key)
    assert_equal "https://discord.com/api/webhooks/123/token", SettingsService.get(:discord_webhook_url)
  end

  test "bulk_update skips env managed keys but persists other settings" do
    SettingsService.set(:oidc_client_secret, "stored-secret")
    SettingsService.set(:max_retries, 10)

    with_env("SHELFARR_SETTING_OIDC_CLIENT_SECRET" => "env-secret") do
      patch bulk_update_admin_settings_url, params: {
        settings: {
          oidc_client_secret: "attempted-secret",
          max_retries: "22"
        }
      }

      assert_redirected_to admin_settings_path
      assert_equal "stored-secret", Setting.find_by(key: "oidc_client_secret").typed_value
      assert_equal "env-secret", SettingsService.get(:oidc_client_secret)
      assert_equal 22, SettingsService.get(:max_retries)
    end
  end

  test "update rejects invalid single path template" do
    patch admin_setting_url("audiobook_path_template"), params: {
      setting: { value: "{invalid_var}" }
    }

    assert_redirected_to admin_settings_path
    assert flash[:alert].present?
  end

  test "update rejects malformed indexer URL without replacing saved value" do
    SettingsService.set(:prowlarr_url, "https://prowlarr.example.com")

    patch admin_setting_url("prowlarr_url"), params: {
      setting: { value: "prowlarr.example.com:9696" }
    }

    assert_redirected_to admin_settings_path
    assert_match(
      %r{Prowlarr URL: must be a valid HTTP or HTTPS URL \(include http:// or https://\)},
      flash[:alert]
    )
    assert_equal "https://prowlarr.example.com", SettingsService.get(:prowlarr_url)
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
    SettingsService.set(:discord_webhook_url, "https://discord.com/api/webhooks/123/token")

    get admin_settings_url

    assert_response :success
    assert_select "label", text: "Discord Enabled"
    assert_select "input[name='settings[discord_enabled]']"
    assert_select "input[type='password'][name='settings[discord_webhook_url]'][value='']"
    assert_select "input[name='settings[discord_events]']"
    assert_no_match %r{https://discord\.com/api/webhooks/123/token}, @response.body
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

  test "bulk_update rejects malformed URLs for every indexer provider" do
    original_urls = {
      prowlarr_url: "https://prowlarr.example.com",
      jackett_url: "https://jackett.example.com",
      newznab_url: "https://newznab.example.com"
    }
    original_urls.each { |key, value| SettingsService.set(key, value) }

    patch bulk_update_admin_settings_url, params: {
      settings: {
        prowlarr_url: "prowlarr.example.com:9696",
        jackett_url: "ftp://jackett.example.com",
        newznab_url: "not a url"
      }
    }

    assert_redirected_to admin_settings_path
    assert_match(
      %r{Prowlarr URL: must be a valid HTTP or HTTPS URL \(include http:// or https://\)},
      flash[:alert]
    )
    assert_match(
      %r{Jackett URL: must be a valid HTTP or HTTPS URL \(include http:// or https://\)},
      flash[:alert]
    )
    # Space-containing values fail URI.parse and include the parser detail.
    assert_match(%r{Newznab URL: must be a valid HTTP or HTTPS URL \(}, flash[:alert])
    assert_match(/not a url/i, flash[:alert])
    original_urls.each do |key, value|
      assert_equal value, SettingsService.get(key), "expected #{key} to keep its saved value"
    end
  end

  test "bulk_update reports malformed indexer URL in turbo response" do
    SettingsService.set(:jackett_url, "https://jackett.example.com")

    patch bulk_update_admin_settings_url,
      params: { settings: { jackett_url: "jackett.example.com:9117" } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match "turbo-stream", response.body
    assert_match "Jackett URL: must be a valid HTTP or HTTPS URL (include http:// or https://)", response.body
    assert_equal "https://jackett.example.com", SettingsService.get(:jackett_url)
  end

  test "bulk_update surfaces URI parse details for invalid indexer URLs" do
    SettingsService.set(:prowlarr_url, "https://prowlarr.example.com")

    patch bulk_update_admin_settings_url, params: {
      settings: { prowlarr_url: "http://[not-a-valid-host" }
    }

    assert_redirected_to admin_settings_path
    assert_match(%r{Prowlarr URL: must be a valid HTTP or HTTPS URL \(}, flash[:alert])
    assert_no_match(/include http:\/\/ or https:\/\//, flash[:alert])
    assert_equal "https://prowlarr.example.com", SettingsService.get(:prowlarr_url)
  end

  test "bulk_update trims valid indexer URLs before saving" do
    patch bulk_update_admin_settings_url, params: {
      settings: { newznab_url: "  https://newznab.example.com/api  " }
    }

    assert_redirected_to admin_settings_path
    assert flash[:alert].blank?
    assert_equal "https://newznab.example.com/api", SettingsService.get(:newznab_url)
  end

  test "bulk_update accepts blank path templates" do
    patch bulk_update_admin_settings_url, params: {
      settings: {
        ebook_path_template: ""
      }
    }

    assert_redirected_to admin_settings_path
    assert_equal "", SettingsService.get(:ebook_path_template)
    assert flash[:alert].blank?
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

  test "test_indexer handles previously stored malformed provider URLs" do
    {
      "prowlarr" => [ :prowlarr_url, :prowlarr_api_key ],
      "jackett" => [ :jackett_url, :jackett_api_key ],
      "newznab" => [ :newznab_url, :newznab_api_key ]
    }.each do |provider, (url_key, api_key)|
      SettingsService.set(:indexer_provider, provider)
      SettingsService.set(url_key, "#{provider}.example.com:1234")
      SettingsService.set(api_key, "test-api-key")
      IndexerClient.reset_all_connections!

      post test_indexer_admin_settings_url

      assert_redirected_to admin_settings_path
      assert_match(/connection failed/i, flash[:alert], "expected #{provider} to fail without a server error")
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

  test "test_indexer succeeds for newznab when selected" do
    SettingsService.set(:indexer_provider, "newznab")
    SettingsService.set(:newznab_url, "http://localhost:5076")
    SettingsService.set(:newznab_api_key, "newznab-key")

    VCR.turned_off do
      stub_request(:get, "http://localhost:5076/api")
        .with(query: hash_including("apikey" => "newznab-key", "t" => "caps"))
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

  test "test_ebooks_com requires opt in and a valid country code" do
    post test_ebooks_com_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /two-letter buyer country/i, flash[:alert]
  end

  test "test_ebooks_com succeeds when the catalog is reachable" do
    SettingsService.set(:ebooks_com_enabled, true)
    SettingsService.set(:ebooks_com_country_code, "PT")

    EbooksComClient.stub :test_connection, true do
      post test_ebooks_com_admin_settings_url,
        headers: { "HTTP_REFERER" => "http://[malformed" }
    end

    assert_redirected_to admin_settings_path
    assert_match /successful/i, flash[:notice]
  end

  test "test_ebooks_com reports a catalog failure" do
    SettingsService.set(:ebooks_com_enabled, true)
    SettingsService.set(:ebooks_com_country_code, "PT")

    EbooksComClient.stub :test_connection, false do
      post test_ebooks_com_admin_settings_url
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

    LibraryPlatformClient.stub(:test_connection, -> { raise LibraryPlatformClient::Error, "abs boom" }) do
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

  test "test_google_books fails when disabled" do
    SettingsService.set(:google_books_enabled, false)

    post test_google_books_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not enabled/i, flash[:alert]
  end

  test "test_google_books succeeds when connection works" do
    SettingsService.set(:google_books_enabled, true)

    GoogleBooksClient.stub(:test_connection, true) do
      post test_google_books_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /successful/i, flash[:notice]
  end

  test "test_google_books marks provider healthy after success" do
    SettingsService.set(:google_books_enabled, true)
    MetadataProviderStatus.create!(provider: "google_books", status: "auth_failed", last_error: "bad key")

    GoogleBooksClient.stub(:test_connection, true) do
      post test_google_books_admin_settings_url
    end

    assert_equal "healthy", MetadataProviderStatus.for_provider("google_books").status
    assert_nil MetadataProviderStatus.for_provider("google_books").last_error
  end

  test "bulk update of google books api key clears auth failed provider status" do
    MetadataProviderStatus.create!(provider: "google_books", status: "auth_failed", last_error: "bad key")

    patch bulk_update_admin_settings_url, params: {
      settings: {
        google_books_api_key: "new-key"
      }
    }

    status = MetadataProviderStatus.for_provider("google_books")
    assert_equal "unknown", status.status
    assert_nil status.last_error
  end

  test "bulk update of metadata provider priority clears all provider status" do
    MetadataProviderStatus.create!(provider: "hardcover", status: "auth_failed", last_error: "bad token")
    MetadataProviderStatus.create!(provider: "google_books", status: "rate_limited", last_error: "quota", rate_limited_until: 5.minutes.from_now)
    MetadataProviderStatus.create!(provider: "openlibrary", status: "down", last_error: "timeout")

    patch bulk_update_admin_settings_url, params: {
      settings: {
        metadata_provider_priority: "google_books,openlibrary,hardcover"
      }
    }

    %w[hardcover google_books openlibrary].each do |provider|
      status = MetadataProviderStatus.for_provider(provider)
      assert_equal "unknown", status.status
      assert_nil status.last_error
      assert_nil status.rate_limited_until
    end
  end

  test "test_google_books fails when connection fails" do
    SettingsService.set(:google_books_enabled, true)

    GoogleBooksClient.stub(:test_connection, false) do
      post test_google_books_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /failed/i, flash[:alert]
  end

  test "test_google_books reports client errors" do
    SettingsService.set(:google_books_enabled, true)

    GoogleBooksClient.stub(:test_connection, -> { raise GoogleBooksClient::Error, "google boom" }) do
      post test_google_books_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /google boom/, flash[:alert]
  end

  test "test_open_library fails when disabled" do
    SettingsService.set(:open_library_enabled, false)

    post test_open_library_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not enabled/i, flash[:alert]
  end

  test "test_open_library succeeds when connection works" do
    SettingsService.set(:open_library_enabled, true)

    OpenLibraryClient.stub(:test_connection, true) do
      post test_open_library_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /successful/i, flash[:notice]
  end

  test "test_open_library fails when connection fails" do
    SettingsService.set(:open_library_enabled, true)

    OpenLibraryClient.stub(:test_connection, false) do
      post test_open_library_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /failed/i, flash[:alert]
  end

  test "test_open_library reports client errors" do
    SettingsService.set(:open_library_enabled, true)

    OpenLibraryClient.stub(:test_connection, -> { raise OpenLibraryClient::Error, "open boom" }) do
      post test_open_library_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /open boom/, flash[:alert]
  end

  test "test_comic_vine fails when not configured" do
    SettingsService.set(:comic_vine_enabled, true)
    SettingsService.set(:comic_vine_api_key, "")

    post test_comic_vine_admin_settings_url

    assert_redirected_to admin_settings_path
    assert_match /not configured/i, flash[:alert]
  end

  test "test_comic_vine succeeds when connection works" do
    SettingsService.set(:comic_vine_enabled, true)
    SettingsService.set(:comic_vine_api_key, "comic-key")

    ComicVineClient.stub(:test_connection, true) do
      post test_comic_vine_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /successful/i, flash[:notice]
    assert_equal "healthy", MetadataProviderStatus.for_provider("comic_vine").status
  end

  test "test_comic_vine fails when connection fails" do
    SettingsService.set(:comic_vine_enabled, true)
    SettingsService.set(:comic_vine_api_key, "comic-key")

    ComicVineClient.stub(:test_connection, false) do
      post test_comic_vine_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /failed/i, flash[:alert]
  end

  test "test_comic_vine reports client errors" do
    SettingsService.set(:comic_vine_enabled, true)
    SettingsService.set(:comic_vine_api_key, "comic-key")

    ComicVineClient.stub(:test_connection, -> { raise ComicVineClient::Error, "comic boom" }) do
      post test_comic_vine_admin_settings_url
    end

    assert_redirected_to admin_settings_path
    assert_match /comic boom/, flash[:alert]
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

  test "index merges unavailable persisted library IDs into select options and preserves them on bulk_update" do
    # Configure API details
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "test-api-key")

    # Set persisted values containing library IDs that are NOT in the stubbed api response
    SettingsService.set(:audiobookshelf_audiobook_library_id, "lib-unavailable-delivery")
    SettingsService.set(:audiobookshelf_audiobook_scan_library_ids, "lib-audio,lib-unavailable-scan")

    VCR.turned_off do
      # Mock the API response to return only "lib-audio"
      stub_request(:get, "http://localhost:13378/api/libraries")
        .with(headers: { "Authorization" => "Bearer test-api-key" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "libraries" => [
              { "id" => "lib-audio", "name" => "Audiobooks", "mediaType" => "book", "folders" => [] }
            ]
          }.to_json
        )

      get admin_settings_url
      assert_response :success

      # Verify both unavailable and available options are present and selected in the rendered HTML
      assert_select "select[name='settings[audiobookshelf_audiobook_library_id]']" do
        assert_select "option[value='lib-audio']", text: "Audiobooks (book)"
        assert_select "option[value='lib-unavailable-delivery'][selected]", text: "lib-unavailable-delivery (Unavailable)"
      end

      assert_select "select[name='settings[audiobookshelf_audiobook_scan_library_ids][]'][multiple]" do
        assert_select "option[value='lib-audio'][selected]", text: "Audiobooks (book)"
        assert_select "option[value='lib-unavailable-scan'][selected]", text: "lib-unavailable-scan (Unavailable)"
      end

      # Now simulate the autosave/bulk_update submission of the form.
      # If we submit the values rendered in the select fields, they should be correctly saved back.
      patch bulk_update_admin_settings_url, params: {
        settings: {
          audiobookshelf_audiobook_library_id: "lib-unavailable-delivery",
          audiobookshelf_audiobook_scan_library_ids: ["lib-audio", "lib-unavailable-scan"]
        }
      }

      assert_redirected_to admin_settings_path
      assert_equal "lib-unavailable-delivery", SettingsService.get(:audiobookshelf_audiobook_library_id)
      assert_equal "lib-audio,lib-unavailable-scan", SettingsService.get(:audiobookshelf_audiobook_scan_library_ids)
    end
  end
end
