class CreateKoboTags < ActiveRecord::Migration[8.1]
  def change
    create_table :kobo_tags do |t|
      t.references :kobo_device, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :tag_id, null: false
      t.string :name, null: false
      t.json :items, null: false, default: []
      t.integer :created_revision, null: false
      t.integer :sync_revision, null: false
      t.timestamps
    end
    add_index :kobo_tags, [ :kobo_device_id, :tag_id ], unique: true
    add_index :kobo_tags, [ :kobo_device_id, :sync_revision ]
  end
end
