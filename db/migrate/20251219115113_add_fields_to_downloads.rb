class AddFieldsToDownloads < ActiveRecord::Migration[8.1]
  def change
    add_column :downloads, :external_id, :string unless column_exists?(:downloads, :external_id)
    add_column :downloads, :download_type, :string unless column_exists?(:downloads, :download_type)

    add_index :downloads, :external_id unless index_exists?(:downloads, :external_id)
  end
end
