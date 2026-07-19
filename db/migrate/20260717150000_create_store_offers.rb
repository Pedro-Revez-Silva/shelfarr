# frozen_string_literal: true

class CreateStoreOffers < ActiveRecord::Migration[8.1]
  def change
    create_table :store_offers do |t|
      t.references :request, null: false, foreign_key: { on_delete: :cascade }
      t.string :provider, null: false
      t.string :external_id, null: false
      t.string :title, null: false
      t.string :author
      t.json :isbns, null: false, default: []
      t.string :language
      t.json :formats, null: false, default: []
      t.string :market, null: false
      t.boolean :drm_free, null: false, default: true
      t.string :drm_type
      t.decimal :price_amount, precision: 12, scale: 4
      t.string :price_currency
      t.string :localized_price
      t.string :storefront_url, null: false
      t.string :checkout_url
      t.string :cover_url
      t.datetime :quoted_at

      t.timestamps
    end

    add_index :store_offers, :provider
    add_index :store_offers,
      [ :request_id, :provider, :external_id ],
      unique: true,
      name: "index_store_offers_on_request_provider_external_id"
  end
end
