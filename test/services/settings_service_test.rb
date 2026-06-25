# frozen_string_literal: true

require "test_helper"

class SettingsServiceTest < ActiveSupport::TestCase
  cover "SettingsService*"

  setup do
    Setting.where(key: %w[indexer_provider indexer_search_scope indexer_custom_audiobook_categories indexer_custom_ebook_categories prowlarr_url prowlarr_api_key jackett_url jackett_api_key newznab_url newznab_api_key preferred_download_type preferred_download_types move_completed_downloads zlibrary_enabled zlibrary_url zlibrary_email zlibrary_password gutenberg_enabled gutenberg_url librivox_enabled librivox_url metadata_source metadata_provider_priority hardcover_enabled hardcover_api_token open_library_enabled google_books_enabled]).delete_all
  end

  test "active_indexer_provider falls back to prowlarr for legacy installs" do
    SettingsService.set(:prowlarr_url, "http://localhost:9696")
    SettingsService.set(:prowlarr_api_key, "legacy-key")

    Setting.where(key: "indexer_provider").delete_all

    assert_equal "prowlarr", SettingsService.active_indexer_provider
    assert SettingsService.active_indexer_configured?
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

  test "move completed downloads defaults to disabled" do
    assert_equal false, SettingsService.get(:move_completed_downloads)
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

  test "metadata provider priority normalizes configured order and appends missing providers" do
    SettingsService.set(:metadata_provider_priority, "google_books, unknown openlibrary google_books")

    assert_equal %w[google_books openlibrary hardcover], SettingsService.metadata_provider_priority
  end

  test "enabled metadata providers use all enabled auto providers in priority order" do
    SettingsService.set(:metadata_source, "auto")
    SettingsService.set(:metadata_provider_priority, "google_books,openlibrary")
    SettingsService.set(:hardcover_api_token, "token")

    assert_equal %w[google_books openlibrary hardcover], SettingsService.enabled_metadata_providers
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

  test "env override takes precedence over a stored string value" do
    SettingsService.set(:oidc_issuer, "https://db.example.com")

    with_env("SHELFARR_SETTING_OIDC_ISSUER" => "https://env.example.com") do
      assert_equal "https://env.example.com", SettingsService.get(:oidc_issuer)
      assert SettingsService.env_managed?(:oidc_issuer)
    end

    # Reverts to the database value once the variable is gone.
    assert_equal "https://db.example.com", SettingsService.get(:oidc_issuer)
    assert_not SettingsService.env_managed?(:oidc_issuer)
  end

  test "env override supplies a value when no row exists (survives a DB wipe)" do
    Setting.where(key: "oidc_client_secret").delete_all

    with_env("SHELFARR_SETTING_OIDC_CLIENT_SECRET" => "from-secret") do
      assert_equal "from-secret", SettingsService.get(:oidc_client_secret)
    end
  end

  test "env override casts booleans, integers, and json to the declared type" do
    with_env(
      "SHELFARR_SETTING_OIDC_ENABLED" => "true",
      "SHELFARR_SETTING_QUEUE_BATCH_SIZE" => "12",
      "SHELFARR_SETTING_ENABLED_LANGUAGES" => '["en","fr"]'
    ) do
      assert_equal true, SettingsService.get(:oidc_enabled)
      assert_equal 12, SettingsService.get(:queue_batch_size)
      assert_equal %w[en fr], SettingsService.get(:enabled_languages)
    end
  end

  test "env override can disable a setting enabled in the database" do
    SettingsService.set(:oidc_enabled, true)

    with_env("SHELFARR_SETTING_OIDC_ENABLED" => "false") do
      assert_equal false, SettingsService.get(:oidc_enabled)
    end
  end

  test "oidc and webhook configured? honor env overrides without any DB rows" do
    Setting.where(key: %w[oidc_enabled oidc_issuer oidc_client_id oidc_client_secret webhook_enabled webhook_url]).delete_all

    with_env(
      "SHELFARR_SETTING_OIDC_ENABLED" => "true",
      "SHELFARR_SETTING_OIDC_ISSUER" => "https://auth.example.com",
      "SHELFARR_SETTING_OIDC_CLIENT_ID" => "shelfarr",
      "SHELFARR_SETTING_OIDC_CLIENT_SECRET" => "s3cret",
      "SHELFARR_SETTING_WEBHOOK_ENABLED" => "true",
      "SHELFARR_SETTING_WEBHOOK_URL" => "http://hook.example.com:9000/"
    ) do
      assert SettingsService.oidc_configured?
      assert SettingsService.configured?(:webhook_url)
    end
  end

  test "env_managed_keys lists only keys present in the environment" do
    with_env("SHELFARR_SETTING_WEBHOOK_URL" => "http://hook.example.com/") do
      assert_includes SettingsService.env_managed_keys, :webhook_url
      assert_not_includes SettingsService.env_managed_keys, :oidc_issuer
    end
  end

  test "env_override_name builds the SHELFARR_SETTING_ variable name" do
    assert_equal "SHELFARR_SETTING_OIDC_CLIENT_SECRET", SettingsService.env_override_name(:oidc_client_secret)
  end

  private

  def with_env(vars)
    previous = {}
    vars.each do |name, value|
      previous[name] = ENV.key?(name) ? ENV[name] : :__absent__
      ENV[name] = value
    end
    yield
  ensure
    previous.each do |name, value|
      if value == :__absent__
        ENV.delete(name)
      else
        ENV[name] = value
      end
    end
  end
end
