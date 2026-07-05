class AddBlocklistToSearchResults < ActiveRecord::Migration[8.1]
  def change
    add_column :search_results, :blocklisted_at, :datetime
    add_column :search_results, :blocklist_reason, :string
    add_index :search_results, [ :request_id, :blocklisted_at ]
  end
end
