# frozen_string_literal: true

class CascadeStoreOffersOnRequestDeletion < ActiveRecord::Migration[8.1]
  def up
    return if foreign_key_exists?(:store_offers, :requests, on_delete: :cascade)

    remove_foreign_key :store_offers, :requests if foreign_key_exists?(:store_offers, :requests)
    add_foreign_key :store_offers, :requests, on_delete: :cascade
  end

  def down
    # CreateStoreOffers already defined this cascade before the corrective
    # migration was added. Rolling only this migration back must therefore
    # preserve that prior schema instead of weakening request deletion.
    return if foreign_key_exists?(:store_offers, :requests, on_delete: :cascade)

    remove_foreign_key :store_offers, :requests if foreign_key_exists?(:store_offers, :requests)
    add_foreign_key :store_offers, :requests, on_delete: :cascade
  end
end
