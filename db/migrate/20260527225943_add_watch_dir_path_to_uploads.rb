class AddWatchDirPathToUploads < ActiveRecord::Migration[8.1]
  def change
    add_column :uploads, :watch_dir_path, :string
    add_index :uploads, :watch_dir_path
  end
end
