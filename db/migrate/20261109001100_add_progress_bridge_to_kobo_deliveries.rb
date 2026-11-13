class AddProgressBridgeToKoboDeliveries < ActiveRecord::Migration[8.1]
  def change
    # The latest Kobo reading place and how it relates to shared progress.
    # Unapplied places are kept here so the owner can choose them explicitly.
    add_column :kobo_deliveries, :progress_bridge, :json
  end
end
