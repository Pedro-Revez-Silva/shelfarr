# frozen_string_literal: true

class AddSeparateEditionToOwnedMediaImports < ActiveRecord::Migration[8.1]
  def change
    add_column :owned_media_imports, :separate_edition, :boolean, null: false, default: false
  end
end
