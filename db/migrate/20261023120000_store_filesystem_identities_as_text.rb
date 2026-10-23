# frozen_string_literal: true

class StoreFilesystemIdentitiesAsText < ActiveRecord::Migration[8.1]
  DOWNLOAD_COLUMNS = %i[
    direct_output_root_device
    direct_output_root_inode
    direct_staging_device
    direct_staging_inode
    direct_staging_parent_device
    direct_staging_parent_inode
  ].freeze

  IMPORT_COLUMNS = %i[
    staged_device
    staged_inode
  ].freeze

  def up
    change_identity_columns(:downloads, DOWNLOAD_COLUMNS, :string)
    change_identity_columns(:owned_media_imports, IMPORT_COLUMNS, :string)
  end

  def down
    change_identity_columns(:downloads, DOWNLOAD_COLUMNS, :integer)
    change_identity_columns(:owned_media_imports, IMPORT_COLUMNS, :integer)
  end

  private

  def change_identity_columns(table, columns, type)
    columns.each do |column|
      change_column table, column, type
    end
  end
end
