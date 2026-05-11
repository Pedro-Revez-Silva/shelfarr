class CreateTelegramUpdates < ActiveRecord::Migration[8.1]
  def change
    create_table :telegram_updates do |t|
      t.string :update_id, null: false
      t.string :telegram_user_id
      t.string :chat_id
      t.string :command

      t.timestamps
    end

    add_index :telegram_updates, :update_id, unique: true
    add_index :telegram_updates, [ :telegram_user_id, :created_at ]
  end
end
