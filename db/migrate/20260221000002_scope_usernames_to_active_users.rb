class ScopeUsernamesToActiveUsers < ActiveRecord::Migration[8.1]
  def change
    remove_index :users, :username
    add_index :users, :username, unique: true, where: "deleted_at IS NULL"
  end
end
