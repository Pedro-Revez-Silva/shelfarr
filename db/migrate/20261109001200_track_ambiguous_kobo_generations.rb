class TrackAmbiguousKoboGenerations < ActiveRecord::Migration[8.1]
  def up
    add_column :kobo_deliveries, :progress_generation_ambiguous, :boolean, null: false, default: false
    # Earlier rows do not record whether their entitlement was reused for an
    # older file. Do not infer generation evidence from a download timestamp.
    execute "UPDATE kobo_deliveries SET progress_generation_ambiguous = 1"
  end

  def down
    remove_column :kobo_deliveries, :progress_generation_ambiguous
  end
end
