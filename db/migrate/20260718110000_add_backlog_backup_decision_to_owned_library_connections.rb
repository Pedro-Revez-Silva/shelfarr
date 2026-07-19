# frozen_string_literal: true

class AddBacklogBackupDecisionToOwnedLibraryConnections < ActiveRecord::Migration[8.1]
  def change
    add_column :owned_library_connections, :backlog_backup_decided_at, :datetime
    add_column :owned_media_imports, :dispatched_at, :datetime
  end
end
