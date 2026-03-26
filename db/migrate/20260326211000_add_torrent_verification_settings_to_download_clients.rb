# frozen_string_literal: true

class AddTorrentVerificationSettingsToDownloadClients < ActiveRecord::Migration[8.1]
  def change
    add_column :download_clients, :torrent_verification_max_attempts, :integer, default: 10, null: false
    add_column :download_clients, :torrent_verification_wait_time, :integer, default: 2, null: false
  end
end
