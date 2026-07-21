# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260718112500_cascade_store_offers_on_request_deletion")

class CascadeStoreOffersOnRequestDeletionTest < ActiveSupport::TestCase
  class IsolatedMigrationRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    adapter = ENV.fetch("DB_ADAPTER", "sqlite3")
    database = adapter == "postgresql" ? "shelfarr_test" : ":memory:"
    IsolatedMigrationRecord.establish_connection(adapter: adapter, database: database)
    @connection = IsolatedMigrationRecord.connection

    # Clean up potentially existing tables for postgresql since it doesn't use :memory:
    if @connection.adapter_name == "PostgreSQL"
      @connection.execute("DROP TABLE IF EXISTS store_offers CASCADE")
      @connection.execute("DROP TABLE IF EXISTS requests CASCADE")
    else
      @connection.execute("DROP TABLE IF EXISTS store_offers")
      @connection.execute("DROP TABLE IF EXISTS requests")
    end

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
