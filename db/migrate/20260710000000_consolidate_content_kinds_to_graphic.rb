# frozen_string_literal: true

class ConsolidateContentKindsToGraphic < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE books SET content_kind = 1 WHERE content_kind = 2"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Manga records cannot be distinguished from comics after consolidation"
  end
end
