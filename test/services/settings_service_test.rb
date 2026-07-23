# frozen_string_literal: true

require "test_helper"

class SettingsServiceTest < ActiveSupport::TestCase
  cover "SettingsService*"

  setup do
    clear_settings_env!
    Setting.where(key: %w[
      indexer_provider indexer_search_scope indexer_custom_audiobook_categories indexer_custom_ebook_categories
      prowlarr_url prowlarr_api_key jackett_url jackett_api_key newznab_url newznab_api_key
      preferred_download_type preferred_download_types completed_download_import_mode move_completed_downloads
      split_audiobook_bundle_imports audiobook_path_template api_token
      zlibrary_enabled zlibrary_url zlibrary_email zlibrary_password gutenberg_enabled gutenberg_url librivox_enabled librivox_url
      ebooks_com_enabled ebooks_com_country_code ebooks_com_search_limit
      metadata_source metadata_provider_priority hardcover_enabled hardcover_api_token open_library_enabled google_books_enabled
      comic_vine_enabled comic_vine_api_key
      library_platform audiobookshelf_url audiobookshelf_api_key bookorbit_url bookorbit_username bookorbit_password
      grimmory_url grimmory_username grimmory_password
      oidc_enabled oidc_auto_redirect oidc_provider_name oidc_issuer oidc_client_id oidc_client_secret oidc_scopes
      oidc_link_existing_users oidc_auto_create_users oidc_default_role
      webhook_enabled webhook_url webhook_token webhook_events webhook_topic
    ]).delete_all
  end

  teardown do
    restore_settings_env!
  end

  test "active_indexer_provider falls back to prowlarr for legacy installs" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "legacy-key")

    Setting.where(key: "indexer_provider").delete_all

    assert_equal "prowlarr", SettingsService.active_indexer_provider
    assert SettingsService.active_indexer_configured?
  end

  test "manual save settings include secrets and account identities" do
    grouped_keys = %w[
      anna_archive_api_key anna_archive_enabled anna_archive_url audiobookshelf_api_key
      audiobookshelf_audiobook_library_id audiobookshelf_audiobook_scan_library_ids
      audiobookshelf_comicbook_library_id audiobookshelf_comicbook_scan_library_ids
      audiobookshelf_ebook_library_id audiobookshelf_ebook_scan_library_ids audiobookshelf_url
      bookorbit_password bookorbit_url bookorbit_username grimmory_password grimmory_url
      grimmory_username indexer_provider jackett_api_key jackett_indexer_filter jackett_url library_platform
      newznab_api_key newznab_url oidc_auto_create_users oidc_auto_redirect oidc_client_id
      oidc_client_secret oidc_default_role oidc_enabled oidc_issuer oidc_link_existing_users
      oidc_provider_name oidc_scopes prowlarr_api_key prowlarr_tags prowlarr_url telegram_bot_token telegram_bot_username telegram_enabled
      telegram_request_username telegram_update_mode telegram_webhook_secret webhook_enabled
      webhook_token webhook_url zlibrary_email zlibrary_enabled zlibrary_password zlibrary_url
      hardcover_api_token hardcover_enabled google_books_api_key google_books_enabled
      comic_vine_api_key comic_vine_enabled discord_enabled discord_webhook_url
    ]

    assert_equal grouped_keys.sort, SettingsService::MANUAL_SAVE_SETTING_KEYS.sort
    (grouped_keys + [ "discord_webhook_url" ]).each do |key|
      assert SettingsService.manual_save_setting_key?(key), "expected #{key} to require an explicit save"
    end

    assert_not SettingsService.manual_save_setting_key?(:max_retries)
    assert_not SettingsService.manual_save_setting_key?(:rate_limit_delay)
  end

  test "active_indexer_provider respects explicit jackett selection" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "legacy-key")
    SettingsService.set(:indexer_provider, "jackett")
    SettingsService.set(:jackett_url, "http://localhost:9117")
    SettingsService.set(:jackett_api_key, "jackett-key")

    assert_equal "jackett", SettingsService.active_indexer_provider
    assert SettingsService.active_indexer_configured?
  end

  test "active_indexer_provider respects explicit newznab selection" do
    SettingsService.set(:indexer_provider, "newznab")
    SettingsService.set(:newznab_url, "http://localhost:5076")
    SettingsService.set(:newznab_api_key, "newznab-key")

    assert_equal "newznab", SettingsService.active_indexer_provider
    assert SettingsService.active_indexer_configured?
  end

  test "active_indexer_provider returns none when nothing is configured" do
    assert_equal "none", SettingsService.active_indexer_provider
    assert_not SettingsService.active_indexer_configured?
  end

  test "preferred_download_types defaults to torrent usenet then direct" do
    assert_equal %w[torrent usenet direct], SettingsService.preferred_download_types
  end

  test "preferred_download_types falls back to legacy preferred_download_type" do
    Setting.create!(
      key: "preferred_download_type",
      value: "usenet",
      value_type: "string",
      category: "download",
      description: "Legacy preferred download type"
    )

    assert_equal %w[usenet torrent direct], SettingsService.preferred_download_types
  end

  test "preferred_download_types preserves stored order and appends missing types" do
    SettingsService.set(:preferred_download_types, %w[direct torrent])

    assert_equal %w[direct torrent usenet], SettingsService.preferred_download_types
  end

  test "indexer search scope defaults to broad" do
    assert_equal "broad", SettingsService.active_indexer_search_scope
    assert SettingsService.broad_indexer_search_scope?
  end

  test "indexer search scope ignores invalid values" do
    SettingsService.set(:indexer_search_scope, "unknown")

    assert_equal "broad", SettingsService.active_indexer_search_scope
  end

  test "indexer category ids use default categories" do
    assert_equal [ 3030 ], SettingsService.indexer_category_ids_for(:audiobook)
    assert_equal [ 7020, 7000 ], SettingsService.indexer_category_ids_for(:ebook)
  end

  test "indexer category ids use custom categories when configured" do
    SettingsService.set(:indexer_search_scope, "custom")
    SettingsService.set(:indexer_custom_audiobook_categories, "3030, 3010\n3040")
    SettingsService.set(:indexer_custom_ebook_categories, "7020 7050")

    assert_equal [ 3030, 3010, 3040 ], SettingsService.indexer_category_ids_for(:audiobook)
    assert_equal [ 7020, 7050 ], SettingsService.indexer_category_ids_for(:ebook)
  end

  test "unrestricted indexer search scope sends no categories" do
    SettingsService.set(:indexer_search_scope, "unrestricted")

    assert_equal [], SettingsService.indexer_category_ids_for(:audiobook)
    assert SettingsService.unrestricted_indexer_search_scope?
  end

  test "post processing source path retries has a dedicated default" do
    Setting.where(key: "post_processing_source_path_retries").delete_all

    assert_equal 10, SettingsService.get(:post_processing_source_path_retries)
  end

  test "completed download import mode defaults to copy" do
    assert_equal "copy", SettingsService.get(:completed_download_import_mode)
  end

  test "completed download import mode accepts every supported mode" do
    SettingsService::COMPLETED_DOWNLOAD_IMPORT_MODES.each do |mode|
      assert_equal mode, SettingsService.set(:completed_download_import_mode, mode)

      setting = Setting.find_by!(key: "completed_download_import_mode")
      assert_equal mode, setting.value
      assert_equal "string", setting.value_type
    end
  end

  test "completed download import mode rejects invalid writes" do
    SettingsService.set(:completed_download_import_mode, "move")

    error = assert_raises(ArgumentError) do
      SettingsService.set(:completed_download_import_mode, "rename")
    end

    assert_equal "Completed Download Import Mode must be one of: copy, move, hardlink", error.message
    assert_equal "move", SettingsService.get(:completed_download_import_mode)
  end

  test "completed download import mode safely resolves corrupt persisted values to copy" do
    Setting.create!(
      key: "completed_download_import_mode",
      value: "rename",
      value_type: "string",
      category: "download"
    )

    assert_equal "copy", SettingsService.get(:completed_download_import_mode)
  end

  test "split audiobook bundle imports defaults to disabled" do
    assert_equal false, SettingsService.get(:split_audiobook_bundle_imports)
  end

  test "zlibrary_configured? requires enabled flag and credentials" do
    SettingsService.set(:zlibrary_enabled, true)
    SettingsService.set(:zlibrary_url, "https://z-library.sk")
    SettingsService.set(:zlibrary_email, "reader@example.com")
    SettingsService.set(:zlibrary_password, "secret")

    assert SettingsService.zlibrary_configured?

    SettingsService.set(:zlibrary_enabled, false)
    assert_not SettingsService.zlibrary_configured?
  end

  test "librivox_configured? requires enabled flag and URL" do
    SettingsService.set(:librivox_enabled, true)
    SettingsService.set(:librivox_url, "https://librivox.org")

    assert SettingsService.librivox_configured?

    SettingsService.set(:librivox_enabled, false)
    assert_not SettingsService.librivox_configured?
  end

  test "gutenberg_configured? requires enabled flag and URL" do
    SettingsService.set(:gutenberg_enabled, true)
    SettingsService.set(:gutenberg_url, "https://www.gutenberg.org")

    assert SettingsService.gutenberg_configured?

    SettingsService.set(:gutenberg_enabled, false)
    assert_not SettingsService.gutenberg_configured?
  end

  test "ebooks_com_configured? requires opt in and an explicit two-letter country" do
    assert_not SettingsService.ebooks_com_configured?

    SettingsService.set(:ebooks_com_enabled, true)
    SettingsService.set(:ebooks_com_country_code, "PT")
    assert SettingsService.ebooks_com_configured?

    SettingsService.set(:ebooks_com_country_code, "Portugal")
    assert_not SettingsService.ebooks_com_configured?

    SettingsService.set(:ebooks_com_country_code, "XX")
    assert_not SettingsService.ebooks_com_configured?
  end

  test "ebooks.com store offers are disabled by default without creating settings" do
    Setting.where(key: %w[ebooks_com_enabled ebooks_com_country_code ebooks_com_search_limit]).delete_all

    assert_equal false, SettingsService.get(:ebooks_com_enabled)
    assert_equal "", SettingsService.get(:ebooks_com_country_code)
    assert_equal 5, SettingsService.get(:ebooks_com_search_limit)
  end

  test "changing the eBooks.com market purges stale localized offers" do
    SettingsService.set(:ebooks_com_enabled, true)
    SettingsService.set(:ebooks_com_country_code, "PT")
    requests(:pending_request).store_offers.create!(
      provider: "ebooks_com",
      external_id: "stale-market-offer",
      title: "The Pending Ebook",
      market: "PT",
      drm_free: true,
      formats: [ "epub" ],
      storefront_url: "https://www.ebooks.com/en-pt/book/stale-market-offer/the-pending-ebook/"
    )

    assert_difference "StoreOffer.count", -1 do
      SettingsService.set(:ebooks_com_country_code, "US")
    end
  end

  test "changing the eBooks.com offer limit preserves still-valid localized offers" do
    SettingsService.set(:ebooks_com_enabled, true)
    SettingsService.set(:ebooks_com_country_code, "PT")
    SettingsService.set(:ebooks_com_search_limit, 5)
    requests(:pending_request).store_offers.create!(
      provider: "ebooks_com",
      external_id: "old-limit-offer",
      title: "The Pending Ebook",
      market: "PT",
      drm_free: true,
      formats: [ "epub" ],
      storefront_url: "https://www.ebooks.com/en-pt/book/old-limit-offer/the-pending-ebook/"
    )

    assert_no_difference "StoreOffer.count" do
      SettingsService.set(:ebooks_com_search_limit, 3)
    end
    assert StoreOffer.exists?(external_id: "old-limit-offer")
  end

  test "metadata provider priority normalizes configured order and appends missing providers" do
    SettingsService.set(:metadata_provider_priority, "google_books, unknown openlibrary google_books")

    assert_equal %w[google_books openlibrary hardcover comic_vine], SettingsService.metadata_provider_priority
  end

  test "enabled metadata providers use all enabled auto providers in priority order" do
    SettingsService.set(:metadata_source, "auto")
    SettingsService.set(:metadata_provider_priority, "google_books,openlibrary")
    SettingsService.set(:hardcover_api_token, "token")

    assert_equal %w[google_books openlibrary hardcover], SettingsService.enabled_metadata_providers
  end

  test "enabled metadata providers append configured Comic Vine for legacy priorities" do
    SettingsService.set(:metadata_source, "auto")
    SettingsService.set(:metadata_provider_priority, "hardcover,openlibrary,google_books")
    SettingsService.set(:hardcover_api_token, "")
    SettingsService.set(:comic_vine_enabled, true)
    SettingsService.set(:comic_vine_api_key, "comic-key")

    assert_equal %w[openlibrary google_books comic_vine], SettingsService.enabled_metadata_providers
  end

  test "enabled metadata providers exclude disabled providers and unconfigured hardcover" do
    SettingsService.set(:metadata_source, "auto")
    SettingsService.set(:google_books_enabled, false)
    SettingsService.set(:hardcover_api_token, "")

    assert_equal %w[openlibrary], SettingsService.enabled_metadata_providers
  end

  test "legacy metadata source restricts search to selected provider" do
    SettingsService.set(:metadata_source, "google_books")
    SettingsService.set(:open_library_enabled, true)
    SettingsService.set(:hardcover_api_token, "token")

    assert_equal %w[google_books], SettingsService.enabled_metadata_providers
  end

  test "legacy metadata source respects provider enabled flag" do
    SettingsService.set(:metadata_source, "openlibrary")
    SettingsService.set(:open_library_enabled, false)

    assert_equal [], SettingsService.enabled_metadata_providers
  end

  test "active_library_platform defaults to audiobookshelf" do
    assert_equal "audiobookshelf", SettingsService.active_library_platform
    assert_not SettingsService.bookorbit_library_platform?
  end

  test "active_library_platform supports bookorbit" do
    SettingsService.set(:library_platform, "bookorbit")

    assert_equal "bookorbit", SettingsService.active_library_platform
    assert SettingsService.bookorbit_library_platform?
  end

  test "label_for uses brand and neutral library platform labels" do
    assert_equal "BookOrbit URL", SettingsService.label_for(:bookorbit_url)
    assert_equal "Grimmory URL", SettingsService.label_for(:grimmory_url)
    assert_equal "Audiobook Library", SettingsService.label_for(:audiobookshelf_audiobook_library_id)
    assert_equal "Comics & Manga Library", SettingsService.label_for(:audiobookshelf_comicbook_library_id)
    assert_equal "Max Retries", SettingsService.label_for(:max_retries)
  end

  test "library_id_for_book resolves separate comic library with ebook fallback" do
    SettingsService.set(:audiobookshelf_audiobook_library_id, "audio-lib")
    SettingsService.set(:audiobookshelf_ebook_library_id, "ebook-lib")
    SettingsService.set(:audiobookshelf_comicbook_library_id, "")

    assert_equal "audio-lib", SettingsService.library_id_for_book(Book.new(book_type: :audiobook))
    assert_equal "ebook-lib", SettingsService.library_id_for_book(Book.new(book_type: :ebook))
    assert_equal "ebook-lib", SettingsService.library_id_for_book(Book.new(book_type: :comicbook))

    SettingsService.set(:audiobookshelf_comicbook_library_id, "comic-lib")
    assert_equal "comic-lib", SettingsService.library_id_for_book(Book.new(book_type: :comicbook))
  end

  test "active_library_platform supports grimmory" do
    SettingsService.set(:library_platform, "grimmory")

    assert_equal "grimmory", SettingsService.active_library_platform
    assert SettingsService.grimmory_library_platform?
  end

  test "audiobookshelf_configured? checks active platform credentials" do
    SettingsService.set(:library_platform, "audiobookshelf")
    SettingsService.set(:audiobookshelf_url, "http://localhost:13378")
    SettingsService.set(:audiobookshelf_api_key, "abs-key")

    assert SettingsService.audiobookshelf_configured?

    SettingsService.set(:library_platform, "bookorbit")
    assert_not SettingsService.audiobookshelf_configured?

    SettingsService.set(:bookorbit_url, "http://localhost:3000")
    SettingsService.set(:bookorbit_username, "admin")
    SettingsService.set(:bookorbit_password, "secret")

    assert SettingsService.audiobookshelf_configured?

    SettingsService.set(:library_platform, "grimmory")
    assert_not SettingsService.audiobookshelf_configured?

    SettingsService.set(:grimmory_url, "http://localhost:5173")
    SettingsService.set(:grimmory_username, "admin")
    SettingsService.set(:grimmory_password, "secret")

    assert SettingsService.audiobookshelf_configured?
  end

  test "env override name uses setting prefix and uppercased key" do
    assert_equal "SHELFARR_SETTING_OIDC_CLIENT_SECRET", SettingsService.env_override_name(:oidc_client_secret)
  end

  test "env value takes precedence over stored value and reverts when removed" do
    SettingsService.set(:oidc_client_id, "stored-client")

    with_env("SHELFARR_SETTING_OIDC_CLIENT_ID" => "env-client") do
      assert_equal "env-client", SettingsService.get(:oidc_client_id)
      assert SettingsService.env_managed?(:oidc_client_id)
    end

    assert_equal "stored-client", SettingsService.get(:oidc_client_id)
    assert_not SettingsService.env_managed?(:oidc_client_id)
  end

  test "env supplies a value when no database row exists" do
    Setting.where(key: "oidc_client_secret").delete_all

    with_env("SHELFARR_SETTING_OIDC_CLIENT_SECRET" => "env-secret") do
      assert_equal "env-secret", SettingsService.get(:oidc_client_secret)
      assert_equal [ :oidc_client_secret ], SettingsService.env_managed_keys
    end
  end

  test "env boolean values use setting type casting" do
    with_env(
      "SHELFARR_SETTING_OIDC_ENABLED" => "true",
      "SHELFARR_SETTING_OIDC_AUTO_CREATE_USERS" => "false"
    ) do
      assert_equal true, SettingsService.get(:oidc_enabled)
      assert_equal false, SettingsService.get(:oidc_auto_create_users)
    end
  end

  test "env string values use setting type casting" do
    with_env("SHELFARR_SETTING_WEBHOOK_EVENTS" => "request_created,request_completed") do
      assert_equal "request_created,request_completed", SettingsService.get(:webhook_events)
    end
  end

  test "env can force a stored enabled setting off" do
    SettingsService.set(:oidc_enabled, true)

    with_env("SHELFARR_SETTING_OIDC_ENABLED" => "false") do
      assert_equal false, SettingsService.get(:oidc_enabled)
    end
  end

  test "oidc_configured? honors env with no database rows" do
    Setting.where(key: %w[oidc_enabled oidc_issuer oidc_client_id oidc_client_secret]).delete_all

    with_env(
      "SHELFARR_SETTING_OIDC_ENABLED" => "true",
      "SHELFARR_SETTING_OIDC_ISSUER" => "https://auth.example.com",
      "SHELFARR_SETTING_OIDC_CLIENT_ID" => "client-id",
      "SHELFARR_SETTING_OIDC_CLIENT_SECRET" => "client-secret"
    ) do
      assert SettingsService.oidc_configured?
    end
  end

  test "configured? honors env with no database rows" do
    Setting.where(key: "webhook_url").delete_all

    with_env("SHELFARR_SETTING_WEBHOOK_URL" => "https://hooks.example.com/shelfarr") do
      assert SettingsService.configured?(:webhook_url)
    end
  end

  test "all_by_category includes env management metadata" do
    with_env("SHELFARR_SETTING_WEBHOOK_URL" => "https://hooks.example.com/shelfarr") do
      webhook_url = SettingsService.all_by_category.dig("webhook", :webhook_url)

      assert_equal true, webhook_url[:env_managed]
      assert_equal "SHELFARR_SETTING_WEBHOOK_URL", webhook_url[:env_var]
    end
  end

  test "non-allowlisted path template env key is inert" do
    SettingsService.set(:audiobook_path_template, "{author}/{title}")

    with_env("SHELFARR_SETTING_AUDIOBOOK_PATH_TEMPLATE" => "{title}") do
      assert_equal "{author}/{title}", SettingsService.get(:audiobook_path_template)
      assert_not SettingsService.env_managed?(:audiobook_path_template)
    end
  end

  test "non-allowlisted api token env key is inert" do
    SettingsService.set(:api_token, "stored-api-token")

    with_env("SHELFARR_SETTING_API_TOKEN" => "env-api-token") do
      assert_equal "stored-api-token", SettingsService.get(:api_token)
      assert_equal "stored-api-token", SettingsService.api_token
      assert_not SettingsService.env_managed?(:api_token)
    end
  end

  test "env override with empty string yields blank value instead of default" do
    with_env("SHELFARR_SETTING_OIDC_PROVIDER_NAME" => "") do
      assert SettingsService.env_managed?(:oidc_provider_name)
      assert_equal "", SettingsService.get(:oidc_provider_name)
      assert_not SettingsService.configured?(:oidc_provider_name)
    end
  end

  test "unrecognized_env_override_names flags unknown and non-overridable keys" do
    with_env(
      "SHELFARR_SETTING_OIDC_ENABLED" => "true",
      "SHELFARR_SETTING_NO_SUCH_SETTING" => "value",
      "SHELFARR_SETTING_AUDIOBOOK_PATH_TEMPLATE" => "{title}"
    ) do
      names = SettingsService.unrecognized_env_override_names

      assert_includes names, "SHELFARR_SETTING_NO_SUCH_SETTING"
      assert_includes names, "SHELFARR_SETTING_AUDIOBOOK_PATH_TEMPLATE"
      assert_not_includes names, "SHELFARR_SETTING_OIDC_ENABLED"
    end
  end

  test "unrecognized_env_override_names flags variables that are not fully uppercased" do
    with_env("SHELFARR_SETTING_oidc_enabled" => "true") do
      assert_includes SettingsService.unrecognized_env_override_names, "SHELFARR_SETTING_oidc_enabled"
      assert_not SettingsService.env_managed?(:oidc_enabled)
    end
  end
end
