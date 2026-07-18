# frozen_string_literal: true

class AddStagedIdentityToOwnedMediaImports < ActiveRecord::Migration[8.1]
  def change
    change_table :owned_media_imports, bulk: true do |table|
      table.integer :staged_device
      table.integer :staged_inode
    end
  end
end
