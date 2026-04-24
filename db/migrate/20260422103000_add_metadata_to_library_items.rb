# frozen_string_literal: true

class AddMetadataToLibraryItems < ActiveRecord::Migration[8.0]
  def change
    change_table :library_items, bulk: true do |t|
      t.string :subtitle
      t.string :narrator
      t.string :series
      t.string :series_position
      t.string :publisher
      t.string :language
      t.string :isbn
      t.string :asin
      t.integer :published_year
      t.text :description
      t.boolean :missing, null: false, default: false
    end

    add_index :library_items, :missing
    add_index :library_items, :isbn
  end
end
