class AddMetadataSourceToBooks < ActiveRecord::Migration[8.1]
  def change
    add_column :books, :metadata_source, :string, default: "openlibrary"
    add_column :books, :hardcover_id, :string
    add_index :books, :hardcover_id
  end
end
