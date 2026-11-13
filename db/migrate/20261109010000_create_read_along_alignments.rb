class CreateReadAlongAlignments < ActiveRecord::Migration[8.1]
  def change
    # An imported text/audio alignment between one EPUB generation and the
    # exact audiobook files it was computed from. Bound by content digests
    # and by the asset generations verified at import; never inferred.
    create_table :read_along_alignments do |t|
      t.references :ebook_book, null: false, foreign_key: { to_table: :books, on_delete: :cascade }, index: { unique: true }
      t.references :audiobook_book, null: false, foreign_key: { to_table: :books, on_delete: :cascade }
      t.references :imported_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :ebook_asset_id, null: false
      t.string :ebook_sha256, null: false
      t.json :audio, null: false
      t.string :document_sha256, null: false
      t.string :tool
      t.integer :cue_count, null: false
      t.binary :cues_gzip, null: false
      t.json :coverage, null: false
      t.timestamps
    end
  end
end
