class CreateUserBookPaths < ActiveRecord::Migration[8.0]
  def change
    create_table :user_book_paths do |t|
      t.references :user, null: false, foreign_key: true
      t.references :book, null: false, foreign_key: true
      t.string :file_path, null: false
      t.timestamps
    end

    add_index :user_book_paths, [ :user_id, :book_id ], unique: true
  end
end
