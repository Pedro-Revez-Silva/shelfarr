class CreateConsumerReadingStates < ActiveRecord::Migration[8.1]
  def change
    create_table :consumer_reading_states do |t|
      t.references :user, null: false, foreign_key: true
      t.references :book, null: false, foreign_key: true
      t.integer :status, null: false, default: 0
      t.timestamps
    end
    add_index :consumer_reading_states, [ :user_id, :book_id ], unique: true
    add_check_constraint :consumer_reading_states, "status IN (0, 1, 2)", name: "consumer_reading_status"
  end
end
