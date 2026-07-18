# frozen_string_literal: true

require "test_helper"

class BetaUpgradeCompatibilityTest < ActiveSupport::TestCase
  test "seeding beta defaults and adding its encrypted model preserve legacy configuration" do
    user = User.create!(
      username: "upgrade_compatibility",
      name: "Upgrade Compatibility",
      password: "Password123!",
      password_confirmation: "Password123!",
      otp_secret: "LEGACYOTPSECRET",
      backup_codes: "legacy-code-hash-one,legacy-code-hash-two"
    )
    download_client = DownloadClient.create!(
      name: "Upgrade compatibility client",
      client_type: "qbittorrent",
      url: "https://downloads.example",
      username: "legacy-reader",
      password: "legacy-password",
      api_key: "legacy-client-api-key"
    )
    acquisition_provider = AcquisitionProvider.create!(
      name: "Upgrade compatibility provider",
      url: "https://provider.example",
      api_key: "legacy-provider-api-key"
    )
    SettingsService.set(:prowlarr_api_key, "legacy-prowlarr-key")
    SettingsService.set(:audiobook_output_path, "/legacy/audiobooks")

    encrypted_snapshots = {
      user_otp: user.reload.otp_secret_before_type_cast,
      user_backup_codes: user.backup_codes_before_type_cast,
      download_client_password: download_client.reload.password_before_type_cast,
      download_client_api_key: download_client.api_key_before_type_cast,
      acquisition_provider_api_key: acquisition_provider.reload.api_key_before_type_cast
    }
    setting_snapshots = Setting.where(
      key: %w[prowlarr_api_key audiobook_output_path]
    ).pluck(:key, :value, :value_type, :category, :description).to_h do |row|
      [ row.first, row.drop(1) ]
    end

    Setting.where(
      key: %w[ebooks_com_enabled ebooks_com_country_code ebooks_com_search_limit]
    ).delete_all
    SettingsService.seed_defaults!
    owned_connection = OwnedLibraryConnection.create!(
      provider: "libation",
      name: "Upgrade compatibility companion",
      url: OwnedLibraryConnection.default_libation_url,
      enabled: false,
      bridge_token: "new-companion-token"
    )

    assert_equal false, SettingsService.get(:ebooks_com_enabled)
    assert_equal "", SettingsService.get(:ebooks_com_country_code)
    assert_equal 5, SettingsService.get(:ebooks_com_search_limit)
    assert_not_equal "new-companion-token", owned_connection.reload.bridge_token_before_type_cast
    assert_equal "new-companion-token", owned_connection.bridge_token

    assert_equal encrypted_snapshots.fetch(:user_otp), user.reload.otp_secret_before_type_cast
    assert_equal encrypted_snapshots.fetch(:user_backup_codes), user.backup_codes_before_type_cast
    assert_equal encrypted_snapshots.fetch(:download_client_password),
      download_client.reload.password_before_type_cast
    assert_equal encrypted_snapshots.fetch(:download_client_api_key),
      download_client.api_key_before_type_cast
    assert_equal encrypted_snapshots.fetch(:acquisition_provider_api_key),
      acquisition_provider.reload.api_key_before_type_cast
    assert_equal "LEGACYOTPSECRET", user.otp_secret
    assert_equal "legacy-code-hash-one,legacy-code-hash-two", user.backup_codes
    assert_equal "legacy-password", download_client.password
    assert_equal "legacy-client-api-key", download_client.api_key
    assert_equal "legacy-provider-api-key", acquisition_provider.api_key

    current_settings = Setting.where(key: setting_snapshots.keys)
      .pluck(:key, :value, :value_type, :category, :description)
      .to_h { |row| [ row.first, row.drop(1) ] }
    assert_equal setting_snapshots, current_settings
  end
end
