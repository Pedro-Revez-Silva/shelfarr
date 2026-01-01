class AddScoringToSearchResults < ActiveRecord::Migration[8.1]
  def change
    add_column :search_results, :detected_language, :string
    add_column :search_results, :confidence_score, :integer
    add_column :search_results, :score_breakdown, :json
  end
end
