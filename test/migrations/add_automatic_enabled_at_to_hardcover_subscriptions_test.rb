# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261010150000_add_automatic_enabled_at_to_hardcover_subscriptions")

class AddAutomaticEnabledAtToHardcoverSubscriptionsTest < ActiveSupport::TestCase
  class IsolatedMigrationRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  test "enabled subscriptions keep their baseline, disabled subscriptions have no boundary, and rollback removes it" do
    IsolatedMigrationRecord.establish_connection(adapter: "sqlite3", database: ":memory:")
    connection = IsolatedMigrationRecord.connection
    connection.create_table(:hardcover_subscriptions) do |table|
      table.boolean :automatic, null: false, default: false
      table.datetime :baseline_established_at
      table.datetime :created_at, null: false
    end
    connection.execute("INSERT INTO hardcover_subscriptions (automatic, baseline_established_at, created_at) VALUES (TRUE, '2026-10-01 12:00:00', '2026-09-30 12:00:00'), (TRUE, NULL, '2026-10-02 12:00:00'), (FALSE, '2026-10-03 12:00:00', '2026-10-02 12:00:00')")
    migration = AddAutomaticEnabledAtToHardcoverSubscriptions.new
    migration.define_singleton_method(:connection) { connection }

    migration.up

    assert_equal [ "2026-10-01 12:00:00", "2026-10-02 12:00:00", nil ], connection.select_values("SELECT automatic_enabled_at FROM hardcover_subscriptions ORDER BY id")
    migration.down
    assert_not connection.column_exists?(:hardcover_subscriptions, :automatic_enabled_at)
  ensure
    IsolatedMigrationRecord.remove_connection
  end
end
