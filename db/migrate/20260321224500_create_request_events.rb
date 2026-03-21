class CreateRequestEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :request_events do |t|
      t.references :request, null: false, foreign_key: true
      t.references :download, null: true, foreign_key: true
      t.integer :level, null: false, default: 0
      t.string :event_type, null: false
      t.string :source, null: false
      t.text :message
      t.json :details, default: {}
      t.boolean :user_visible, null: false, default: false

      t.timestamps
    end

    add_index :request_events, :event_type
    add_index :request_events, :created_at
  end
end
