# frozen_string_literal: true

class AddSearchGenerationToRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :requests, :search_generation, :bigint, default: 0, null: false
  end
end
