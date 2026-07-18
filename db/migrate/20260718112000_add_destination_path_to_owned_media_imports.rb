# frozen_string_literal: true

class AddDestinationPathToOwnedMediaImports < ActiveRecord::Migration[8.1]
  ACTIVE_IMPORT_STATUSES = %w[queued starting downloading processing].freeze

  def change
    add_column :owned_media_imports, :destination_path, :string
    add_index :owned_media_imports,
      :destination_path,
      unique: true,
      where: "destination_path IS NOT NULL AND status IN (#{ACTIVE_IMPORT_STATUSES.map { |status| connection.quote(status) }.join(', ')})",
      name: "index_owned_media_imports_on_active_destination"
  end
end
