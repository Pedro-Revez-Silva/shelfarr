class AddOidcFieldsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :oidc_uid, :string
    add_index :users, :oidc_uid
    add_column :users, :oidc_provider, :string
  end
end
