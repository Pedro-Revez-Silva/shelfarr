# frozen_string_literal: true

class AddCreatedBookToOwnedMediaImports < ActiveRecord::Migration[8.1]
  def change
    add_reference :owned_media_imports,
      :created_book,
      null: true,
      foreign_key: { to_table: :books, on_delete: :nullify }
  end
end
