class AddNotFoundCountToDownloads < ActiveRecord::Migration[8.1]
  def change
    add_column :downloads, :not_found_count, :integer, default: 0, null: false
  end
end
