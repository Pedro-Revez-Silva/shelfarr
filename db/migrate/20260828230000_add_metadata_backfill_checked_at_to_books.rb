# frozen_string_literal: true

class AddMetadataBackfillCheckedAtToBooks < ActiveRecord::Migration[8.1]
  def change
    add_column :books, :metadata_backfill_checked_at, :datetime
    add_index :books, :metadata_backfill_checked_at
  end
end
