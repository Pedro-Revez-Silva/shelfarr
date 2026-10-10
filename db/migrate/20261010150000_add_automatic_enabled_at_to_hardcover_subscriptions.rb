class AddAutomaticEnabledAtToHardcoverSubscriptions < ActiveRecord::Migration[8.1]
  def up
    add_column :hardcover_subscriptions, :automatic_enabled_at, :datetime

    # Existing enabled subscriptions have no toggle history. Preserve their
    # established baseline rather than inventing a later enable time.
    execute <<~SQL
      UPDATE hardcover_subscriptions
      SET automatic_enabled_at = COALESCE(baseline_established_at, created_at)
      WHERE automatic = TRUE
    SQL
  end

  def down
    remove_column :hardcover_subscriptions, :automatic_enabled_at
  end
end
