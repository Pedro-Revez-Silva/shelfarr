class AddDownloadPathToDownloadClients < ActiveRecord::Migration[8.1]
  def change
    add_column :download_clients, :download_path, :string
  end
end
