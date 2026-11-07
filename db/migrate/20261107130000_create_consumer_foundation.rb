class CreateConsumerFoundation < ActiveRecord::Migration[8.1]
  def change
    create_table :consumer_device_grants do |t|
      t.references :user, foreign_key: true
      t.string :client_name, null: false
      t.string :device_code_digest, null: false
      t.string :user_code_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :approved_at
      t.datetime :denied_at
      t.datetime :consumed_at
      t.datetime :last_polled_at
      t.integer :poll_interval, default: 5, null: false
      t.timestamps
    end
    add_index :consumer_device_grants, :device_code_digest, unique: true
    add_index :consumer_device_grants, :user_code_digest, unique: true
    add_index :consumer_device_grants, :expires_at

    create_table :consumer_progresses do |t|
      t.references :user, null: false, foreign_key: true
      t.references :book, null: false, foreign_key: true
      t.string :asset_id, null: false
      t.json :locator
      t.float :position_seconds
      t.integer :version, default: 1, null: false
      t.string :client_mutation_id, null: false
      t.timestamps
    end
    add_index :consumer_progresses, [ :user_id, :book_id ], unique: true
  end
end
