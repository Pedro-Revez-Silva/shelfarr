# frozen_string_literal: true

class AddReferenceTargetRootsToBooks < ActiveRecord::Migration[8.1]
  def change
    add_column :books, :reference_target_roots, :text
  end
end
