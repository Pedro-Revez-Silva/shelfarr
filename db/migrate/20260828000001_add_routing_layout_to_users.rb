class AddRoutingLayoutToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :routing_layout, :string, default: "single_path", null: false
  end
end
