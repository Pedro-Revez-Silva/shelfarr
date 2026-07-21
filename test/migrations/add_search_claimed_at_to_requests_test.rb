# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260718122000_add_search_claimed_at_to_requests")

class AddSearchClaimedAtToRequestsTest < ActiveSupport::TestCase
  class IsolatedMigrationRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    adapter = ENV.fetch("DB_ADAPTER", "sqlite3")
    database = adapter == "postgresql" ? "shelfarr_test" : ":memory:"
    IsolatedMigrationRecord.establish_connection(adapter: adapter, database: database)
    @connection = IsolatedMigrationRecord.connection

    if @connection.adapter_name == "PostgreSQL"
      @connection.execute("DROP TABLE IF EXISTS request_events CASCADE")
      @connection.execute("DROP TABLE IF EXISTS requests CASCADE")
    else
      @connection.execute("DROP TABLE IF EXISTS request_events")
      @connection.execute("DROP TABLE IF EXISTS requests")
    end

    @connection.create_table(:requests) do |table|
      table.integer :status, null: false
      table.boolean :attention_needed, default: false
      table.datetime :updated_at, null: false
    end
    @connection.create_table(:request_events) do |table|
      table.integer :request_id, null: false
      table.string :event_type, null: false
      table.string :source, null: false
      table.datetime :created_at, null: false
    end
  end

  teardown do
    IsolatedMigrationRecord.remove_connection
  end

  test "backfills only legacy in-flight searches and rolls back cleanly" do
    in_flight_id = insert_request(status: 1, attention_needed: false, updated_at: 45.minutes.ago)
    refreshed_attention_id = insert_request(status: 1, attention_needed: true, updated_at: 30.minutes.ago)
    insert_attention_event(request_id: refreshed_attention_id, created_at: 2.hours.ago)
    manual_review_updated_at = 2.hours.ago
    manual_review_id = insert_request(
      status: 1,
      attention_needed: true,
      updated_at: manual_review_updated_at
    )
    insert_attention_event(request_id: manual_review_id, created_at: manual_review_updated_at + 1.second)
    pending_id = insert_request(status: 0, attention_needed: false, updated_at: 1.hour.ago)
    migration = AddSearchClaimedAtToRequests.new
    isolated_connection = @connection
    migration.define_singleton_method(:connection) { isolated_connection }

    migration.up

    assert @connection.index_exists?(:requests, [ :status, :search_claimed_at ])
    assert_not_nil claim_for(in_flight_id)
    assert_not_nil claim_for(refreshed_attention_id)
    assert_nil claim_for(manual_review_id)
    assert_nil claim_for(pending_id)

    migration.down

    assert_not @connection.column_exists?(:requests, :search_claimed_at)
  end

  private

  def insert_request(status:, attention_needed:, updated_at:)
    quoted_time = @connection.quote(updated_at)
    attention_val = if @connection.adapter_name == "PostgreSQL"
      attention_needed ? "TRUE" : "FALSE"
    else
      attention_needed ? 1 : 0
    end

    @connection.execute(<<~SQL.squish)
      INSERT INTO requests (status, attention_needed, updated_at)
      VALUES (#{Integer(status)}, #{attention_val}, #{quoted_time})
    SQL
    @connection.select_value("SELECT MAX(id) FROM requests").to_i
  end

  def claim_for(id)
    @connection.select_value(
      "SELECT search_claimed_at FROM requests WHERE id = #{Integer(id)}"
    )
  end

  def insert_attention_event(request_id:, created_at:)
    @connection.execute(<<~SQL.squish)
      INSERT INTO request_events (request_id, event_type, source, created_at)
      VALUES (
        #{Integer(request_id)},
        'attention_flagged',
        'request',
        #{@connection.quote(created_at)}
      )
    SQL
  end
end
