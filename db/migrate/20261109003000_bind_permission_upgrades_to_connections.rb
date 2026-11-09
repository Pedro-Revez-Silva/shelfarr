class BindPermissionUpgradesToConnections < ActiveRecord::Migration[8.1]
  def change
    # Internal lineage survives adoption, when replaces_api_token_id is cleared.
    # Legacy tokens acquire a lineage only when they are upgraded.
    add_column :api_tokens, :connection_key, :string
    add_index :api_tokens, [ :user_id, :connection_key ]
  end
end
