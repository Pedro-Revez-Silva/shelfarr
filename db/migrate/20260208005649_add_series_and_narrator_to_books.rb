class AddSeriesAndNarratorToBooks < ActiveRecord::Migration[8.0]
  def change
    add_column :books, :series, :string
    add_column :books, :narrator, :string
  end
end
