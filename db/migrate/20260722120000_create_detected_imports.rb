# frozen_string_literal: true

class CreateDetectedImports < ActiveRecord::Migration[8.1]
  def change
    create_table :detected_imports do |t|
      t.references :suggested_book, null: true, foreign_key: { to_table: :books, on_delete: :nullify }
      t.references :imported_book, null: true, foreign_key: { to_table: :books, on_delete: :nullify }
      t.string :source_path, null: false
      t.bigint :source_device
      t.bigint :source_inode
      t.string :content_fingerprint
      t.string :book_type
      t.string :parsed_title
      t.string :parsed_author
      t.integer :match_confidence
      t.json :candidate_books, null: false, default: []
      t.string :status, null: false, default: "detected"
      t.text :error_message
      t.datetime :detected_at

      t.timestamps
    end

    add_index :detected_imports, :status
    add_index :detected_imports, :detected_at
    add_index :detected_imports,
      [ :source_device, :source_inode ],
      unique: true,
      where: "source_device IS NOT NULL AND source_inode IS NOT NULL",
      name: "index_detected_imports_on_source_identity"
  end
end
