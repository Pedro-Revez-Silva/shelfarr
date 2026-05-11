class CreateTelegramChatAuthorizations < ActiveRecord::Migration[8.1]
  def change
    create_table :telegram_chat_authorizations do |t|
      t.string :chat_id, null: false
      t.string :chat_title
      t.string :code_digest
      t.datetime :code_generated_at
      t.datetime :approved_at
      t.references :approved_by, foreign_key: { to_table: :users }
      t.string :requested_by_telegram_user_id
      t.string :requested_by_telegram_username

      t.timestamps
    end

    add_index :telegram_chat_authorizations, :chat_id, unique: true
    add_index :telegram_chat_authorizations, :code_generated_at
    add_index :telegram_chat_authorizations, :approved_at
  end
end
