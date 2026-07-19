# frozen_string_literal: true

class CreateOwnedLibraryRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :owned_library_connections do |t|
      t.string :provider, null: false
      t.string :name, null: false
      t.string :url, null: false
      t.text :bridge_token
      t.boolean :enabled, null: false, default: false
      t.boolean :allow_private_network, null: false, default: true
      t.integer :timeout_seconds, null: false, default: 30
      t.string :sync_status, null: false, default: "idle"
      t.string :sync_job_id
      t.datetime :sync_started_at
      t.datetime :last_synced_at
      t.text :last_sync_error
      t.string :companion_version
      t.string :provider_version

      t.timestamps
    end

    add_index :owned_library_connections, :provider, unique: true
    add_index :owned_library_connections, :enabled
    add_index :owned_library_connections, :sync_status

    create_table :owned_library_items do |t|
      t.references :owned_library_connection, null: false, foreign_key: true
      t.references :book, null: true, foreign_key: { on_delete: :nullify }
      t.string :external_id, null: false
      t.string :media_type, null: false, default: "audiobook"
      t.string :title, null: false
      t.string :subtitle
      t.json :authors, null: false, default: []
      t.json :narrators, null: false, default: []
      t.string :cover_url
      t.string :language
      t.integer :duration_seconds
      t.string :ownership_type, null: false, default: "unknown"
      t.datetime :purchased_at
      t.boolean :active, null: false, default: true
      t.boolean :downloaded, null: false, default: false
      t.datetime :backed_up_at
      t.string :file_path
      t.datetime :last_seen_at
      t.datetime :absent_since
      t.json :provider_metadata, null: false, default: {}

      t.timestamps
    end

    add_index :owned_library_items,
      [ :owned_library_connection_id, :external_id ],
      unique: true,
      name: "index_owned_library_items_on_connection_and_external_id"
    add_index :owned_library_items, [ :owned_library_connection_id, :active ]
    add_index :owned_library_items, :ownership_type
    add_index :owned_library_items, :title

    create_table :owned_media_imports do |t|
      t.references :owned_library_item, null: false, foreign_key: true
      t.references :request, null: true, foreign_key: { on_delete: :nullify }
      t.references :upload, null: true, foreign_key: { on_delete: :nullify }
      t.bigint :requested_by_id
      t.string :status, null: false, default: "queued"
      t.string :external_job_id
      t.string :artifact_path
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    add_foreign_key :owned_media_imports, :users, column: :requested_by_id, on_delete: :nullify
    add_index :owned_media_imports, :requested_by_id
    add_index :owned_media_imports, :status
    add_index :owned_media_imports,
      :external_job_id,
      unique: true,
      where: "external_job_id IS NOT NULL"
    add_index :owned_media_imports,
      :owned_library_item_id,
      unique: true,
      where: "status IN ('queued', 'starting', 'downloading', 'processing')",
      name: "index_owned_media_imports_on_item_active"
  end
end
