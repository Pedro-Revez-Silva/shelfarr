# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261122120000_add_blocklisted_info_hash_to_downloads")

class AddBlocklistedInfoHashToDownloadsTest < ActiveSupport::TestCase
  class IsolatedMigrationRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  HASH = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

  setup do
    IsolatedMigrationRecord.establish_connection(adapter: "sqlite3", database: ":memory:")
    @connection = IsolatedMigrationRecord.connection
    @connection.create_table(:downloads) do |table|
      table.integer :request_id
      table.integer :status, null: false, default: 0
      table.integer :search_result_id
      table.string :download_type
      table.string :external_id
      table.integer :not_found_count, null: false, default: 0
    end
    @connection.create_table(:search_results) do |table|
      table.integer :request_id
      table.string :guid
      table.datetime :blocklisted_at
    end
    @connection.create_table(:request_events) do |table|
      table.integer :download_id
      table.string :event_type, null: false
    end
  end

  teardown do
    IsolatedMigrationRecord.remove_connection
  end

  test "records failed torrent hashes from monitor misses and blocklisted releases only" do
    blocklisted_result = insert_search_result(blocklisted: true)
    healthy_result = insert_search_result(blocklisted: false)
    switched_then_blocklisted = insert_search_result(blocklisted: true)
    rows = {
      ratio_removed: insert_download(request_id: 1, external_id: HASH.upcase, not_found_count: 3),
      blocklisted_opaque_url: insert_download(request_id: 2, external_id: "b" * 40, search_result_id: blocklisted_result),
      blocklisted_then_refreshed: insert_download(request_id: 8, external_id: "9" * 40, search_result_id: nil),
      cancelled_with_other_event: insert_download(request_id: 9, external_id: "8" * 40, search_result_id: nil),
      switched_away_before_retry_failed: insert_download(request_id: 10, external_id: "7" * 40, search_result_id: switched_then_blocklisted),
      manual_switch: insert_download(request_id: 3, external_id: "c" * 40, not_found_count: 1, search_result_id: healthy_result),
      usenet: insert_download(request_id: 4, external_id: "d" * 40, download_type: "usenet", not_found_count: 3),
      client_handle: insert_download(request_id: 5, external_id: "SABnzbd_nzo_1", not_found_count: 3),
      not_failed: insert_download(request_id: 6, external_id: "e" * 40, status: "completed", not_found_count: 3)
    }
    rows[:reselected] = insert_download(request_id: 7, external_id: "f" * 40, not_found_count: 3)
    insert_download(request_id: 7, external_id: "f" * 40, status: "completed")
    rows[:overridden_then_switched_away] = insert_download(request_id: 11, external_id: "6" * 40, not_found_count: 3)
    rows[:healthy_retry_cancelled] = insert_download(request_id: 11, external_id: "6" * 40)
    insert_download(request_id: 10, external_id: nil, search_result_id: switched_then_blocklisted)
    insert_event(rows[:blocklisted_then_refreshed], "release_blocklisted")
    insert_event(rows[:cancelled_with_other_event], "dispatch_failed")

    run_migration

    assert_equal(
      {
        ratio_removed: HASH,
        blocklisted_opaque_url: "b" * 40,
        blocklisted_then_refreshed: "9" * 40,
        cancelled_with_other_event: nil,
        switched_away_before_retry_failed: nil,
        manual_switch: nil,
        usenet: nil,
        client_handle: nil,
        not_failed: nil,
        reselected: nil,
        overridden_then_switched_away: nil,
        healthy_retry_cancelled: nil
      },
      rows.transform_values { |id| blocklisted_hash(id) }
    )
    assert_equal "guid-#{blocklisted_result}", blocklisted_guid(rows[:blocklisted_opaque_url])
    assert_nil blocklisted_guid(rows[:ratio_removed])
  end

  private

  def insert_search_result(blocklisted:)
    @connection.execute(<<~SQL.squish)
      INSERT INTO search_results (request_id, blocklisted_at)
      VALUES (1, #{blocklisted ? "CURRENT_TIMESTAMP" : "NULL"})
    SQL
    id = @connection.select_value("SELECT MAX(id) FROM search_results").to_i
    @connection.execute("UPDATE search_results SET guid = 'guid-#{id}' WHERE id = #{id}")
    id
  end

  def insert_event(download_id, event_type)
    @connection.execute(<<~SQL.squish)
      INSERT INTO request_events (download_id, event_type)
      VALUES (#{Integer(download_id)}, #{@connection.quote(event_type)})
    SQL
  end

  def insert_download(request_id:, external_id:, status: "failed", download_type: "torrent", not_found_count: 0, search_result_id: nil)
    columns = {
      "request_id" => request_id,
      "status" => Download.statuses.fetch(status),
      "download_type" => download_type,
      "external_id" => external_id,
      "not_found_count" => not_found_count,
      "search_result_id" => search_result_id
    }
    values = columns.values.map { |value| @connection.quote(value) }
    @connection.execute("INSERT INTO downloads (#{columns.keys.join(", ")}) VALUES (#{values.join(", ")})")
    @connection.select_value("SELECT MAX(id) FROM downloads").to_i
  end

  def blocklisted_hash(id)
    @connection.select_value("SELECT blocklisted_info_hash FROM downloads WHERE id = #{Integer(id)}")
  end

  def blocklisted_guid(id)
    @connection.select_value("SELECT blocklisted_release_guid FROM downloads WHERE id = #{Integer(id)}")
  end

  def run_migration
    migration = AddBlocklistedInfoHashToDownloads.new
    migration.verbose = false
    connection = @connection
    migration.define_singleton_method(:connection) { connection }
    migration.up
  end
end
