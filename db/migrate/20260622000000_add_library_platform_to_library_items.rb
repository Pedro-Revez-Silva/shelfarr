# frozen_string_literal: true

class AddLibraryPlatformToLibraryItems < ActiveRecord::Migration[8.1]
  def change
    add_column :library_items, :library_platform, :string, null: false, default: "audiobookshelf"

    remove_index :library_items, [ :library_id, :audiobookshelf_id ]
    add_index :library_items, [ :library_platform, :library_id, :audiobookshelf_id ], unique: true
    add_index :library_items, :library_platform
  end
end
