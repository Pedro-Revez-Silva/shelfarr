# frozen_string_literal: true

class AddBookTypeToLibraryItems < ActiveRecord::Migration[8.1]
  def change
    add_column :library_items, :book_type, :string
    add_index :library_items, [ :library_platform, :missing, :book_type ]
  end
end
