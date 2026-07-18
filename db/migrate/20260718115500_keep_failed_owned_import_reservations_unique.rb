# frozen_string_literal: true

class KeepFailedOwnedImportReservationsUnique < ActiveRecord::Migration[8.1]
  ACTIVE_STATUSES = %w[queued starting downloading processing].freeze

  def up
    remove_index :owned_media_imports, name: "index_owned_media_imports_on_item_active"
    remove_index :owned_media_imports, name: "index_owned_media_imports_on_active_destination"
    remove_index :owned_media_imports, name: "index_owned_media_imports_on_active_library_path"

    add_index :owned_media_imports,
      :owned_library_item_id,
      unique: true,
      where: blocking_item_predicate,
      name: "index_owned_media_imports_on_item_active"
    add_index :owned_media_imports,
      :destination_path,
      unique: true,
      where: "destination_path IS NOT NULL AND status != 'completed'",
      name: "index_owned_media_imports_on_active_destination"
    add_index :owned_media_imports,
      :library_path,
      unique: true,
      where: "library_path IS NOT NULL AND status != 'completed'",
      name: "index_owned_media_imports_on_active_library_path"
  end

  def down
    remove_index :owned_media_imports, name: "index_owned_media_imports_on_item_active"
    remove_index :owned_media_imports, name: "index_owned_media_imports_on_active_destination"
    remove_index :owned_media_imports, name: "index_owned_media_imports_on_active_library_path"

    add_index :owned_media_imports,
      :owned_library_item_id,
      unique: true,
      where: active_predicate,
      name: "index_owned_media_imports_on_item_active"
    add_index :owned_media_imports,
      :destination_path,
      unique: true,
      where: "destination_path IS NOT NULL AND status IN (#{quoted_active_statuses})",
      name: "index_owned_media_imports_on_active_destination"
    add_index :owned_media_imports,
      :library_path,
      unique: true,
      where: "library_path IS NOT NULL AND status IN (#{quoted_active_statuses})",
      name: "index_owned_media_imports_on_active_library_path"
  end

  private

  def blocking_item_predicate
    "status IN (#{quoted_active_statuses}) OR " \
      "(destination_path IS NOT NULL AND status != 'completed')"
  end

  def active_predicate
    "status IN (#{quoted_active_statuses})"
  end

  def quoted_active_statuses
    ACTIVE_STATUSES.map { |status| connection.quote(status) }.join(", ")
  end
end
