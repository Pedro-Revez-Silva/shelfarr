class AddStoreCoexistenceToKoboDevices < ActiveRecord::Migration[8.1]
  def change
    # Existing readers keep their current Shelfarr-only behavior until their
    # owner opts in. Store authentication is never stored here.
    add_column :kobo_devices, :store_coexistence, :boolean, null: false, default: false
    add_column :kobo_devices, :share_progress, :boolean, null: false, default: false
    add_column :kobo_devices, :store_status, :string
    add_column :kobo_devices, :store_checked_at, :datetime
    add_column :kobo_devices, :placeholder_auth_at, :datetime
  end
end
