# frozen_string_literal: true

class AddActiveLibraryPathIndexToOwnedMediaImports < ActiveRecord::Migration[8.1]
  ACTIVE_IMPORT_STATUSES = %w[queued starting downloading processing].freeze

  def change
    add_index :owned_media_imports,
      :library_path,
      unique: true,
      where: "library_path IS NOT NULL AND status IN (#{ACTIVE_IMPORT_STATUSES.map { |status| connection.quote(status) }.join(', ')})",
      name: "index_owned_media_imports_on_active_library_path"
  end
end
