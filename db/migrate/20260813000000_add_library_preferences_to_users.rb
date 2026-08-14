# frozen_string_literal: true

class AddLibraryPreferencesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :preferred_audiobook_library_id, :string
    add_column :users, :preferred_ebook_library_id, :string
    add_column :users, :preferred_comicbook_library_id, :string
  end
end
