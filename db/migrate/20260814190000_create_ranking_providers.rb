# frozen_string_literal: true

class CreateRankingProviders < ActiveRecord::Migration[8.1]
  def change
    create_table :ranking_providers do |t|
      t.string :name, null: false
      t.string :url, null: false
      t.string :api_key
      t.boolean :enabled, null: false, default: true
      t.boolean :allow_private_network, null: false, default: false
      t.integer :priority, null: false, default: 0
      t.integer :timeout_seconds, null: false, default: 30

      t.timestamps
    end

    add_index :ranking_providers, :name, unique: true
    add_index :ranking_providers, [ :enabled, :priority ]
  end
end
