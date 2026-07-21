class CreateSearchResults < ActiveRecord::Migration[8.1]
  def change
    create_table :search_results do |t|
      t.references :request, null: false, foreign_key: true
      t.string :guid, null: false
      t.string :title, null: false
      t.string :indexer
      t.bigint :size_bytes
      t.integer :seeders
      t.integer :leechers
      t.string :download_url
      t.string :magnet_url
      t.string :info_url
      t.datetime :published_at
      t.integer :status, default: 0, null: false

      t.timestamps

      t.index [ :request_id, :guid ], unique: true
    end
  end
end
