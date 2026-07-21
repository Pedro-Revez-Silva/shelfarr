class CreateRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :requests do |t|
      t.references :book, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :status, null: false, default: 0
      t.text :notes
      t.integer :retry_count, default: 0
      t.datetime :next_retry_at
      t.datetime :completed_at
      t.boolean :attention_needed, default: false
      t.text :issue_description

      t.timestamps
    end

    add_index :requests, :status
    add_index :requests, :next_retry_at
    add_index :requests, :attention_needed
    add_index :requests, [ :user_id, :status ]
  end
end
