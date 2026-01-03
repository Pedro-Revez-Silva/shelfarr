class AddSourceToSearchResults < ActiveRecord::Migration[8.1]
  def change
    add_column :search_results, :source, :string, default: "prowlarr"
  end
end
