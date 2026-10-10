class CreateHardcoverIntegration < ActiveRecord::Migration[8.1]
  def change
    create_table :hardcover_connections do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :auth_method, null: false
      t.text :access_token, null: false
      t.text :refresh_token
      t.datetime :access_token_expires_at
      t.string :granted_scopes
      t.integer :hardcover_user_id, null: false
      t.string :hardcover_username
      t.string :status, null: false, default: "active"
      t.string :last_error
      t.datetime :last_verified_at
      t.datetime :refreshed_at
      t.timestamps
    end
    add_index :hardcover_connections, :hardcover_user_id

    create_table :hardcover_subscriptions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :target_key, null: false
      t.integer :hardcover_target_id
      t.string :title, null: false
      t.string :slug
      t.text :description
      t.string :image_url
      t.string :owner_username
      t.json :book_types, null: false, default: []
      t.boolean :automatic, null: false, default: false
      t.string :status, null: false, default: "draft"
      t.string :pause_reason
      t.string :snapshot_state, null: false, default: "pending"
      t.datetime :snapshot_completed_at
      t.integer :entries_seen_count, null: false, default: 0
      t.boolean :entries_truncated, null: false, default: false
      t.json :exclusions, null: false, default: {}
      t.datetime :baseline_established_at
      t.datetime :sync_cursor_at
      t.datetime :last_synced_at
      t.datetime :next_sync_at
      t.text :last_error
      t.integer :consecutive_failures, null: false, default: 0
      t.timestamps
    end
    add_index :hardcover_subscriptions, [ :user_id, :target_key ], unique: true
    add_index :hardcover_subscriptions, [ :status, :next_sync_at ]

    create_table :hardcover_subscription_items do |t|
      t.references :hardcover_subscription, null: false, foreign_key: true
      t.integer :hardcover_book_id, null: false
      t.string :title, null: false
      t.string :author
      t.string :cover_url
      t.text :description
      t.date :release_date
      t.integer :release_year
      t.string :series_name
      t.string :series_position
      t.integer :users_count
      t.boolean :has_audiobook, null: false, default: false
      t.boolean :has_ebook, null: false, default: false
      t.datetime :entry_added_at
      t.integer :position
      t.string :state, null: false
      t.boolean :wanted, null: false, default: false
      t.json :book_types, null: false, default: []
      t.json :request_ids, null: false, default: []
      t.integer :attempts, null: false, default: 0
      t.string :claim_token
      t.datetime :claimed_at
      t.datetime :last_attempt_at
      t.datetime :next_attempt_at
      t.text :last_error
      t.string :resolution
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :hardcover_subscription_items, [ :hardcover_subscription_id, :hardcover_book_id ],
      unique: true, name: "index_hardcover_items_on_subscription_and_book"
    add_index :hardcover_subscription_items, [ :state, :next_attempt_at ],
      name: "index_hardcover_items_on_state_and_next_attempt"
    add_index :hardcover_subscription_items, [ :state, :release_date ],
      name: "index_hardcover_items_on_state_and_release_date"
  end
end
