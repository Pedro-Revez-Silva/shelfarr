# frozen_string_literal: true

class AddRecoveryReservationToUploads < ActiveRecord::Migration[8.1]
  def change
    add_column :uploads, :destination_path, :string
    add_column :uploads, :destination_root, :string
    add_column :uploads, :destination_configured_root, :string
    add_column :uploads, :library_path, :string
    add_column :uploads, :content_sha256, :string
    add_column :uploads, :cleanup_source_path, :string

    add_index :uploads,
      :destination_path,
      unique: true,
      where: "destination_path IS NOT NULL AND status IN (0, 1, 3)",
      name: "index_active_uploads_on_destination_path"
    add_index :uploads,
      :library_path,
      unique: true,
      where: "library_path IS NOT NULL AND status IN (0, 1, 3)",
      name: "index_active_uploads_on_library_path"
  end
end
