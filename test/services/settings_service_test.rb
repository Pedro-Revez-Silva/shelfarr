# frozen_string_literal: true

require "test_helper"

class SettingsServiceTest < ActiveSupport::TestCase
  setup do
    Setting.where(key: %w[indexer_provider prowlarr_url prowlarr_api_key jackett_url jackett_api_key]).delete_all
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
end
