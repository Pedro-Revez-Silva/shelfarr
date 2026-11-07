class CreateKoboDevices < ActiveRecord::Migration[8.1]
  def change
    create_table :kobo_devices do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :base_url, null: false
      t.string :token_digest, null: false
      t.integer :sync_revision, null: false, default: 0
      t.datetime :last_sync_at
      t.timestamps
    end
    add_index :kobo_devices, :token_digest, unique: true

    create_table :kobo_deliveries do |t|
      t.references :kobo_device, null: false, foreign_key: true
      t.references :book, foreign_key: true
      t.string :entitlement_id, null: false
      t.string :revision_id, null: false
      t.integer :sync_revision, null: false
      t.json :publication, null: false
      t.json :reading_state
      t.datetime :last_download_at
      t.timestamps
    end
    add_index :kobo_deliveries, [ :kobo_device_id, :book_id ], unique: true
    add_index :kobo_deliveries, :entitlement_id, unique: true
    add_index :kobo_deliveries, [ :kobo_device_id, :sync_revision ]
  end
end
