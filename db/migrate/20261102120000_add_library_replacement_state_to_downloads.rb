# frozen_string_literal: true

class AddLibraryReplacementStateToDownloads < ActiveRecord::Migration[8.1]
  def change
    add_column :downloads, :library_replacement_state, :text
  end
end
