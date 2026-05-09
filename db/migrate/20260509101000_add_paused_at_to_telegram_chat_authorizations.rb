class AddPausedAtToTelegramChatAuthorizations < ActiveRecord::Migration[8.1]
  def change
    add_column :telegram_chat_authorizations, :paused_at, :datetime
    add_index :telegram_chat_authorizations, :paused_at
  end
end
