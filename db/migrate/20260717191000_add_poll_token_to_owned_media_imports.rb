# frozen_string_literal: true

class AddPollTokenToOwnedMediaImports < ActiveRecord::Migration[8.1]
  def change
    add_column :owned_media_imports, :poll_token, :string
  end
end
