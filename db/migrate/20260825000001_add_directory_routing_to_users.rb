class AddDirectoryRoutingToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :preferred_output_path, :string
    add_column :users, :library_routing_mode, :string
  end
end
