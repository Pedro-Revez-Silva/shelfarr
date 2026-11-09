# Owner-controlled household sharing of Kobo account catalogues, a private
# owner/edition-bound cache of DRM-free purchases, and delivery of a cached
# file to a recipient's own stock Kobo. Nothing enters the shared Book table.
class CreateKoboHouseholdSharing < ActiveRecord::Migration[8.1]
  def change
    # Delivery rights recorded from catalogue metadata. Download URLs are
    # signed and short-lived: they are fetched again when a file is prepared
    # and never stored. A NULL check time means the row predates this check.
    change_table :kobo_account_books, bulk: true do |t|
      t.string :rights
      t.string :download_format
      t.bigint :download_size
      t.datetime :rights_checked_at
    end

    create_table :kobo_account_shares do |t|
      t.references :kobo_account, null: false, foreign_key: true
      t.references :recipient, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :kobo_account_shares, [ :kobo_account_id, :recipient_id ], unique: true

    create_table :kobo_account_book_files do |t|
      t.references :kobo_account_book, null: false, foreign_key: true
      t.references :requested_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :status, null: false, default: "fetching"
      t.string :request_id, null: false
      t.string :kobo_revision_id
      t.string :format
      t.bigint :expected_size
      t.bigint :size_bytes
      t.string :sha256
      t.string :epub_version
      t.string :storage_key
      t.text :file_device
      t.text :file_inode
      t.string :error
      t.datetime :started_at
      t.datetime :fetched_at
      t.datetime :last_used_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :kobo_account_book_files, [ :kobo_account_book_id, :status ]
    add_index :kobo_account_book_files, :storage_key

    change_table :kobo_deliveries, bulk: true do |t|
      t.references :kobo_account_book, foreign_key: true
      t.references :kobo_account_share, foreign_key: true
      t.references :kobo_account_book_file, foreign_key: true
    end
    add_index :kobo_deliveries, [ :kobo_device_id, :kobo_account_book_id ], unique: true
  end
end
