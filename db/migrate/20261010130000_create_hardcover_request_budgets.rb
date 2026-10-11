class CreateHardcoverRequestBudgets < ActiveRecord::Migration[8.1]
  def change
    # Automatic Hardcover requests each user has used in the current check
    # window. Kept in the database so continuation batches, restarts, and
    # every subscription of the user share one budget.
    create_table :hardcover_request_budgets do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.datetime :window_started_at, null: false
      t.integer :used, null: false, default: 0
      t.timestamps
    end
  end
end
