class CreateDownloadClients < ActiveRecord::Migration[8.1]
  def change
    create_table :download_clients do |t|
      t.string :name, null: false
      t.string :client_type, null: false
      t.string :url, null: false
      t.string :username
      t.string :password
      t.string :api_key
      t.string :category
      t.integer :priority, default: 0, null: false
      t.boolean :enabled, default: true, null: false

      t.timestamps
    end

    add_index :download_clients, :name, unique: true
    add_index :download_clients, [ :client_type, :priority ]
    add_index :download_clients, :enabled
  end
end
