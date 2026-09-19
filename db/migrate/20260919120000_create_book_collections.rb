class CreateBookCollections < ActiveRecord::Migration[8.1]
  def change
    create_table :book_works do |t|
      t.string :source, null: false
      t.string :source_id, null: false
      t.string :title, null: false
      t.string :author
      t.string :cover_url
      t.text :description
      t.integer :release_year
      t.timestamps
      t.index [ :source, :source_id ], unique: true
    end

    add_reference :books, :book_work, foreign_key: true

    create_table :book_collections do |t|
      t.string :source, null: false
      t.string :source_id, null: false
      t.string :title, null: false
      t.string :author
      t.string :cover_url
      t.text :description
      t.datetime :synced_at
      t.timestamps
      t.index [ :source, :source_id ], unique: true
    end

    create_table :collection_memberships do |t|
      t.references :book_collection, null: false, foreign_key: true
      t.references :book_work, null: false, foreign_key: true
      t.string :position
      t.integer :sort_order, null: false, default: 0
      t.boolean :ambiguous, null: false, default: false
      t.timestamps
      t.index [ :book_collection_id, :book_work_id ], unique: true, name: "index_collection_memberships_on_collection_and_work"
    end
  end
end
