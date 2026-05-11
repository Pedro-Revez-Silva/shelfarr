class AddTelegramIdentityToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :telegram_user_id, :string
    add_column :users, :telegram_username, :string
    add_column :users, :telegram_link_token_digest, :string
    add_column :users, :telegram_link_token_created_at, :datetime

    add_index :users, :telegram_user_id,
      unique: true,
      where: "deleted_at IS NULL AND telegram_user_id IS NOT NULL",
      name: "index_users_on_telegram_user_id_unique"
    add_index :users, :telegram_link_token_digest
  end
end
