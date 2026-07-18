# frozen_string_literal: true

class AddDirectDownloadRecoveryState < ActiveRecord::Migration[8.1]
  def change
    add_column :books, :acquisition_reservation_token, :string
    add_column :books, :acquisition_reservation_owner_type, :string
    add_column :books, :acquisition_reservation_owner_id, :integer

    add_index :books,
      :acquisition_reservation_token,
      unique: true,
      where: "acquisition_reservation_token IS NOT NULL",
      name: "index_books_on_acquisition_reservation_token"

    add_column :downloads, :direct_reservation_token, :string
    add_column :downloads, :direct_staging_path, :string
    add_column :downloads, :direct_staging_device, :integer
    add_column :downloads, :direct_staging_inode, :integer
    add_column :downloads, :direct_staging_parent_device, :integer
    add_column :downloads, :direct_staging_parent_inode, :integer
    add_column :downloads, :direct_destination_path, :string
    add_column :downloads, :direct_book_path, :string
    add_column :downloads, :direct_output_root, :string
    add_column :downloads, :direct_output_root_device, :integer
    add_column :downloads, :direct_output_root_inode, :integer
    add_column :downloads, :direct_publication_kind, :string
    add_column :downloads, :direct_content_manifest, :text

    add_index :downloads,
      :direct_reservation_token,
      unique: true,
      where: "direct_reservation_token IS NOT NULL",
      name: "index_downloads_on_direct_reservation_token"
    add_index :downloads,
      :direct_staging_path,
      where: "direct_staging_path IS NOT NULL",
      name: "index_downloads_on_direct_staging_path"
  end
end
