# frozen_string_literal: true

class AddSearchResultToDownloads < ActiveRecord::Migration[8.1]
  def change
    add_reference :downloads, :search_result, foreign_key: { on_delete: :nullify }, index: true
  end
end
