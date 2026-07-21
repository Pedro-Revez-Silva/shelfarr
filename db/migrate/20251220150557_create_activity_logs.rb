class CreateActivityLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :activity_logs do |t|
      t.references :user, foreign_key: true
      t.references :trackable, polymorphic: true
      t.string :action, null: false
      t.string :controller
      t.string :ip_address
      t.json :details, default: {}

      t.timestamps
    end

    add_index :activity_logs, :action
    add_index :activity_logs, :created_at
    add_index :activity_logs, [ :trackable_type, :trackable_id ]
  end
end
