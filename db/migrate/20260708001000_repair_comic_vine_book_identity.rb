# frozen_string_literal: true

class RepairComicVineBookIdentity < ActiveRecord::Migration[8.1]
  def up
    add_column :books, :comic_vine_id, :string unless column_exists?(:books, :comic_vine_id)
    add_index :books, :comic_vine_id unless index_exists?(:books, :comic_vine_id)
  end

  def down
    # The primary comic support migration owns this column on fresh installs.
    # This repair migration only backfills upgraded databases that had an
    # earlier incomplete migration state, so rollback must not remove it.
  end
end
