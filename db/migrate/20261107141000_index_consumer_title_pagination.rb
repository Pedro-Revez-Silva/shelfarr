class IndexConsumerTitlePagination < ActiveRecord::Migration[8.1]
  def change
    add_index :books, "LOWER(COALESCE(title, '')), id",
      name: "index_books_on_consumer_title",
      where: "file_path IS NOT NULL AND TRIM(file_path) <> ''"
  end
end
