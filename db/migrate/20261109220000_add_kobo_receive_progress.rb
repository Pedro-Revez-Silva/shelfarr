# Shelfarr reading places can be sent to a stock Kobo. The opt-in is per
# reader and off for every existing reader until hardware acceptance.
#
# file_sync_revision is the sync revision at which a delivery's file and
# entitlement last changed. sync_revision keeps advancing for later
# reading-state-only changes, so an incremental cursor past the file can still
# receive a place without announcing (or downloading) the book again.
class AddKoboReceiveProgress < ActiveRecord::Migration[8.1]
  def change
    add_column :kobo_devices, :receive_progress, :boolean, default: false, null: false
    add_column :kobo_deliveries, :file_sync_revision, :integer
    add_column :kobo_deliveries, :progress_outbound, :json

    reversible do |direction|
      direction.up { execute "UPDATE kobo_deliveries SET file_sync_revision = sync_revision" }
    end
  end
end
