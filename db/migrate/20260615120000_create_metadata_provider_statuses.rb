class CreateMetadataProviderStatuses < ActiveRecord::Migration[8.1]
  def change
    create_table :metadata_provider_statuses do |t|
      t.string :provider, null: false
      t.string :status, null: false, default: "unknown"
      t.datetime :rate_limited_until
      t.string :last_error
      t.datetime :last_success_at
      t.datetime :last_failure_at
      t.integer :failure_count, default: 0, null: false
      t.timestamps
    end

    add_index :metadata_provider_statuses, :provider, unique: true
  end
end
