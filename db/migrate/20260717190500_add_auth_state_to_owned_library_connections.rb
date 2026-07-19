# frozen_string_literal: true

class AddAuthStateToOwnedLibraryConnections < ActiveRecord::Migration[8.1]
  def change
    change_table :owned_library_connections, bulk: true do |t|
      t.text :auth_session_id
      t.text :auth_login_url
      t.datetime :auth_expires_at
    end
  end
end
