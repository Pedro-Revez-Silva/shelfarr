class AddSeriesPositionToBooks < ActiveRecord::Migration[8.1]
  def change
    add_column :books, :series_position, :string
    add_index :books, :series_position
  end
end
