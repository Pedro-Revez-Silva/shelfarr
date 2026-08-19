# frozen_string_literal: true

class AddSeriesStartYearToBooks < ActiveRecord::Migration[8.1]
  def change
    add_column :books, :series_start_year, :integer
  end
end
