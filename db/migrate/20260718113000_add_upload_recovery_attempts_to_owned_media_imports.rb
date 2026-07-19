# frozen_string_literal: true

class AddUploadRecoveryAttemptsToOwnedMediaImports < ActiveRecord::Migration[8.1]
  def change
    add_column :owned_media_imports,
      :upload_recovery_attempts,
      :integer,
      null: false,
      default: 0
  end
end
