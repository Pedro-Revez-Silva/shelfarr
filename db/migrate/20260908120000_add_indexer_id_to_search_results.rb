# frozen_string_literal: true

class AddIndexerIdToSearchResults < ActiveRecord::Migration[8.1]
  def change
    add_column :search_results, :indexer_id, :integer
  end
end
