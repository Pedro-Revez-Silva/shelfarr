# Locally issued UUIDs remain local even after their deliveries are revoked.
# Retain no title, account, bookmark or file metadata; remove with the reader.
class RememberKoboLocalEntitlements < ActiveRecord::Migration[8.1]
  def change
    create_table :kobo_local_entitlements do |t|
      t.references :kobo_device, null: false, foreign_key: { on_delete: :cascade }
      t.string :entitlement_id, null: false
    end
    add_index :kobo_local_entitlements, [ :kobo_device_id, :entitlement_id ], unique: true

    reversible do |direction|
      direction.up do
        execute <<~SQL
          INSERT INTO kobo_local_entitlements (kobo_device_id, entitlement_id)
          SELECT DISTINCT kobo_device_id, entitlement_id FROM kobo_deliveries
        SQL
      end
    end
  end
end
