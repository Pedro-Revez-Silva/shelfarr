class AddOriginToRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :requests, :created_via, :string, default: "web", null: false
    add_column :requests, :external_source, :string
    add_column :requests, :external_user_id, :string
    add_column :requests, :external_chat_id, :string

    add_index :requests, :created_via
    add_index :requests, [ :external_source, :external_user_id ]
  end
end
