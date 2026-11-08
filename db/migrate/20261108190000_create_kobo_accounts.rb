class CreateKoboAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :kobo_accounts do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :status, null: false, default: "pending"
      t.text :device_id, null: false
      t.text :serial_number, null: false
      t.text :activation_poll_url
      t.text :activation_code
      t.datetime :activation_expires_at
      t.datetime :next_poll_at
      t.text :kobo_user_id
      t.text :kobo_user_key
      t.text :kobo_email
      t.text :access_token
      t.text :refresh_token
      t.string :sync_status, null: false, default: "idle"
      t.string :sync_request_id
      t.datetime :sync_started_at
      t.datetime :last_synced_at
      t.string :last_error
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    create_table :kobo_account_books do |t|
      t.references :kobo_account, null: false, foreign_key: true
      t.string :entitlement_id, null: false
      t.string :revision_id
      t.string :title, null: false
      t.text :author
      t.string :media_type, null: false, default: "ebook"
      t.string :ownership_type, null: false, default: "unknown"
      t.boolean :archived, null: false, default: false
      t.timestamps
    end
    add_index :kobo_account_books, [ :kobo_account_id, :entitlement_id ], unique: true
  end
end
