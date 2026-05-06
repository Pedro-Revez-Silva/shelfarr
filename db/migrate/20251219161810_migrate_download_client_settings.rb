# frozen_string_literal: true

class MigrateDownloadClientSettings < ActiveRecord::Migration[8.1]
  class MigratedDownloadClient < ApplicationRecord
    self.table_name = "download_clients"

    encrypts :password, :api_key
  end

  def up
    # Read old settings from the settings table
    url = Setting.find_by(key: "download_client_url")&.value
    return if url.blank?

    client_type = Setting.find_by(key: "download_client_type")&.value || "qbittorrent"
    username = Setting.find_by(key: "download_client_username")&.value
    password = Setting.find_by(key: "download_client_password")&.value
    api_key = Setting.find_by(key: "download_client_api_key")&.value

    # Create a DownloadClient record
    MigratedDownloadClient.create!(
      name: "#{client_type.titleize} (Migrated)",
      client_type: client_type,
      url: url,
      username: username,
      password: password,
      api_key: api_key,
      priority: 0,
      enabled: true
    )

    # Remove old settings
    Setting.where(key: %w[
      download_client_type
      download_client_url
      download_client_username
      download_client_password
      download_client_api_key
    ]).destroy_all

    Rails.logger.info "[Migration] Migrated download client settings to DownloadClient model"
  end

  def down
    # Can't reliably reverse this migration
    raise ActiveRecord::IrreversibleMigration
  end
end
