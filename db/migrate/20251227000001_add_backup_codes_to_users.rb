# frozen_string_literal: true

class AddBackupCodesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :backup_codes, :text
  end
end
