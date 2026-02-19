# frozen_string_literal: true

class CreateLibraryItems < ActiveRecord::Migration[8.0]
  def change
    create_table :library_items do |t|
      t.string :library_id, null: false
      t.string :audiobookshelf_id, null: false
      t.string :title
      t.string :author
      t.datetime :synced_at

      t.timestamps
    end

    add_index :library_items, [ :library_id, :audiobookshelf_id ], unique: true
    add_index :library_items, :library_id
    add_index :library_items, :synced_at
  end
end
