class AddUniqueIndexToUsersOidcIdentity < ActiveRecord::Migration[8.1]
  def change
    remove_index :users, :oidc_uid if index_exists?(:users, :oidc_uid)

    add_index :users, [ :oidc_provider, :oidc_uid ],
      unique: true,
      where: "deleted_at IS NULL AND oidc_provider IS NOT NULL AND oidc_uid IS NOT NULL",
      name: "index_users_on_oidc_provider_and_uid_unique"
  end
end
