# Kobo editions (KEPUB) prepared from library EPUB files for stock Kobo
# readers. A row exists only for a complete, verified copy. It is bound to the
# converter version and the SHA-256 of the exact source bytes; the source file
# itself is never changed. A delivery references the copy it announced, which
# keeps the copy out of cache eviction.
class CreateKoboKepubCopies < ActiveRecord::Migration[8.1]
  def change
    create_table :kobo_kepub_copies do |t|
      t.string :converter, null: false
      t.string :source_sha256, null: false
      t.bigint :source_size, null: false
      t.string :sha256, null: false
      t.bigint :size_bytes, null: false
      t.string :storage_key, null: false
      t.text :file_device
      t.text :file_inode
      t.string :file_changed_at
      t.integer :chapters, null: false, default: 0
      t.integer :spans, null: false, default: 0
      t.datetime :last_used_at
      t.timestamps
    end
    add_index :kobo_kepub_copies, :storage_key, unique: true
    add_index :kobo_kepub_copies, [ :converter, :source_sha256 ]

    add_reference :kobo_deliveries, :kobo_kepub_copy, foreign_key: { on_delete: :nullify }
  end
end
