class AddGoogleBooksIdToBooks < ActiveRecord::Migration[8.1]
  def change
    add_column :books, :google_books_id, :string
    add_index :books, :google_books_id
  end
end
