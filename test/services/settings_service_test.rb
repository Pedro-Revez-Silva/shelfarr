# frozen_string_literal: true

require "test_helper"

class SettingsServiceTest < ActiveSupport::TestCase
  cover "SettingsService*"

  setup do
    Setting.where(key: %w[indexer_provider indexer_search_scope indexer_custom_audiobook_categories indexer_custom_ebook_categories prowlarr_url prowlarr_api_key jackett_url jackett_api_key preferred_download_type preferred_download_types zlibrary_enabled zlibrary_url zlibrary_email zlibrary_password gutenberg_enabled gutenberg_url librivox_enabled librivox_url]).delete_all
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
end
