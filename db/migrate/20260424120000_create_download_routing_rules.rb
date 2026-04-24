# frozen_string_literal: true

class CreateDownloadRoutingRules < ActiveRecord::Migration[8.1]
  def change
    create_table :download_routing_rules do |t|
      t.string :provider, null: false
      t.string :indexer_name, null: false
      t.string :normalized_indexer_name, null: false
      t.string :download_type, null: false
      t.references :download_client, null: false, foreign_key: true
      t.boolean :enabled, null: false, default: true

      t.timestamps
    end

    add_index :download_routing_rules,
      [ :provider, :normalized_indexer_name, :download_type ],
      unique: true,
      name: "index_download_routing_rules_on_route"
    add_index :download_routing_rules, :enabled
  end
end
