# frozen_string_literal: true

class AddManualMatchCreatedBookToUploads < ActiveRecord::Migration[8.1]
  def change
    add_column :uploads, :manual_match_created_book, :boolean, default: false, null: false
  end
end
