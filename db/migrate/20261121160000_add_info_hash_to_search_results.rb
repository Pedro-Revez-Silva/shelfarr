# frozen_string_literal: true

class AddInfoHashToSearchResults < ActiveRecord::Migration[8.1]
  def change
    add_column :search_results, :info_hash, :string
  end
end
