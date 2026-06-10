# frozen_string_literal: true

class CreateAcquisitionProviders < ActiveRecord::Migration[8.1]
  def change
    create_table :acquisition_providers do |t|
      t.string :name, null: false
      t.string :url, null: false
      t.string :api_key
      t.boolean :enabled, null: false, default: true
      t.boolean :allow_private_network, null: false, default: false
      t.boolean :supports_ebooks, null: false, default: true
      t.boolean :supports_audiobooks, null: false, default: true
      t.integer :priority, null: false, default: 0
      t.integer :timeout_seconds, null: false, default: 30

      t.timestamps
    end

    add_index :acquisition_providers, :enabled
    add_index :acquisition_providers, :name, unique: true
    add_index :acquisition_providers, :priority

    add_reference :search_results, :acquisition_provider, foreign_key: true
    add_column :search_results, :provider_result_id, :string
    add_column :search_results, :provider_payload, :json, default: {}
    add_index :search_results, [ :acquisition_provider_id, :provider_result_id ], name: "index_search_results_on_provider_result"
  end
end
