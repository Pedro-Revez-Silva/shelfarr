# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260718112500_cascade_store_offers_on_request_deletion")

class CascadeStoreOffersOnRequestDeletionTest < ActiveSupport::TestCase
  class IsolatedMigrationRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    IsolatedMigrationRecord.establish_connection(adapter: "sqlite3", database: ":memory:")
    @connection = IsolatedMigrationRecord.connection
    @connection.create_table(:requests)
    @connection.create_table(:store_offers) do |table|
      table.references :request, null: false
    end
    @connection.add_foreign_key :store_offers, :requests, on_delete: :cascade
  end

  teardown do
    IsolatedMigrationRecord.remove_connection
  end

  test "rolling back the corrective migration preserves the original cascade" do
    migration = CascadeStoreOffersOnRequestDeletion.new
    isolated_connection = @connection
    migration.define_singleton_method(:connection) { isolated_connection }

    migration.down

    foreign_key = @connection.foreign_keys(:store_offers).find do |candidate|
      candidate.to_table == "requests"
    end
    assert_equal :cascade, foreign_key&.on_delete
  end
end
