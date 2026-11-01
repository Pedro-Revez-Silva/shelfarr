# frozen_string_literal: true

class AddReplaceLibraryFileToDownloads < ActiveRecord::Migration[8.1]
  def change
    add_column :downloads, :replace_library_file, :boolean, default: false, null: false
  end
end
