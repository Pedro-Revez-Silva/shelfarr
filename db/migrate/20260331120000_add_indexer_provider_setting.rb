class AddIndexerProviderSetting < ActiveRecord::Migration[8.1]
  class MigrationSetting < ApplicationRecord
    self.table_name = "settings"
  end

  def up
    return unless table_exists?(:settings)

    provider = legacy_prowlarr_configured? ? "prowlarr" : "none"

    setting = MigrationSetting.find_or_initialize_by(key: "indexer_provider")
    setting.value = provider
    setting.value_type = "string"
    setting.category = "indexer"
    setting.description = "Active indexer provider. Leave unset on upgrades to keep legacy Prowlarr configuration."
    setting.save!
  end

  def down
    return unless table_exists?(:settings)

    MigrationSetting.where(key: "indexer_provider").delete_all
  end

  private

  def legacy_prowlarr_configured?
    url = MigrationSetting.find_by(key: "prowlarr_url")&.value.to_s.strip
    api_key = MigrationSetting.find_by(key: "prowlarr_api_key")&.value.to_s.strip

    url.present? && api_key.present?
  end
end
