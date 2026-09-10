# frozen_string_literal: true

class AddManualMatchToUploads < ActiveRecord::Migration[8.1]
  def change
    add_column :uploads, :manual_match, :boolean, default: false, null: false
  end
end
