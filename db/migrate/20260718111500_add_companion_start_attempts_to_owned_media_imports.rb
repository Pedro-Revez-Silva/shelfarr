# frozen_string_literal: true

class AddCompanionStartAttemptsToOwnedMediaImports < ActiveRecord::Migration[8.1]
  def change
    add_column :owned_media_imports, :companion_start_attempts, :integer, null: false, default: 0
  end
end
