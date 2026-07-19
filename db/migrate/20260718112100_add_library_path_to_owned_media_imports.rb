# frozen_string_literal: true

class AddLibraryPathToOwnedMediaImports < ActiveRecord::Migration[8.1]
  def change
    add_column :owned_media_imports, :library_path, :string
  end
end
