# frozen_string_literal: true

class AddOwnedLibraryAutomation < ActiveRecord::Migration[8.1]
  def change
    change_table :owned_library_connections, bulk: true do |t|
      t.boolean :scheduled_sync_enabled, null: false, default: false
      t.integer :scheduled_sync_interval_minutes, null: false, default: 1_440
      t.datetime :next_scheduled_sync_at
      t.boolean :automatic_backup_enabled, null: false, default: false
      t.datetime :automatic_backup_enabled_at
      t.references :automatic_backup_user,
        null: true,
        foreign_key: { to_table: :users, on_delete: :nullify }
    end

    add_index :owned_library_connections,
      [ :scheduled_sync_enabled, :next_scheduled_sync_at ],
      name: "index_owned_library_connections_on_scheduled_sync_due"
    add_column :owned_media_imports, :automatic, :boolean, null: false, default: false
  end
end
