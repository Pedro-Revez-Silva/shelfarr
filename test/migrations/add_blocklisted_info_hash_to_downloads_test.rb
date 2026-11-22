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
      table.datetime :created_at
    end
    @connection.create_table(:search_results) do |table|
      table.integer :request_id
      table.string :guid
      table.datetime :blocklisted_at
    end
    @connection.create_table(:request_events) do |table|
      table.integer :request_id
      table.integer :download_id
      table.string :event_type, null: false
      table.json :details, default: {}
      table.datetime :created_at
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

  test "does not record a failure the admin overrode before the retry got a new client id" do
    overridden = insert_search_result(blocklisted: false)
    refailed = insert_search_result(blocklisted: true, at: "2026-01-03 00:00:00")
    overridden_before_failure = insert_search_result(blocklisted: false)
    retried_and_refailed = insert_search_result(blocklisted: false)
    separately_failed = insert_search_result(blocklisted: false)
    retried_as_other_torrent = insert_search_result(blocklisted: false)
    refreshed_away_id = 9_000
    rows = {
      overridden_monitor_miss: insert_download(request_id: 20, external_id: "1" * 40, not_found_count: 3, search_result_id: overridden, at: "2026-01-01 00:00:00"),
      overridden_blocklisted: insert_download(request_id: 21, external_id: "2" * 40, search_result_id: overridden, at: "2026-01-01 00:00:00"),
      refailed_after_override: insert_download(request_id: 22, external_id: "3" * 40, not_found_count: 3, search_result_id: refailed, at: "2026-01-01 00:00:00"),
      failed_after_override: insert_download(request_id: 23, external_id: "4" * 40, not_found_count: 3, search_result_id: overridden_before_failure, at: "2026-01-02 00:00:00"),
      other_release_overridden: insert_download(request_id: 24, external_id: "5" * 40, not_found_count: 3, search_result_id: separately_failed, at: "2026-01-01 00:00:00"),
      retry_refailed_after_override: insert_download(request_id: 25, external_id: "6" * 40, not_found_count: 3, search_result_id: retried_and_refailed, at: "2026-01-01 00:00:00"),
      retry_got_other_torrent: insert_download(request_id: 26, external_id: "a" * 40, not_found_count: 3, search_result_id: retried_as_other_torrent, at: "2026-01-01 00:00:00"),
      refreshed_after_override: insert_download(request_id: 27, external_id: "b" * 40, search_result_id: nil, at: "2026-01-01 00:00:00")
    }
    insert_event(rows[:overridden_blocklisted], "release_blocklisted", request_id: 21, at: "2026-01-01 01:00:00")
    insert_override(request_id: 20, search_result_id: overridden, at: "2026-01-02 00:00:00")
    insert_override(request_id: 21, search_result_id: overridden, at: "2026-01-02 00:00:00")
    insert_override(request_id: 22, search_result_id: refailed, at: "2026-01-02 00:00:00")
    insert_override(request_id: 23, search_result_id: overridden_before_failure, at: "2026-01-01 00:00:00")
    insert_override(request_id: 24, search_result_id: overridden, at: "2026-01-02 00:00:00")
    insert_download(request_id: 20, external_id: nil, search_result_id: overridden, at: "2026-01-02 00:00:01")
    insert_download(request_id: 21, external_id: nil, status: "failed", search_result_id: overridden, at: "2026-01-02 00:00:01")
    insert_override(request_id: 25, search_result_id: retried_and_refailed, at: "2026-01-02 00:00:00")
    refailed_retry = insert_download(request_id: 25, external_id: nil, search_result_id: retried_and_refailed, at: "2026-01-02 00:00:01")
    insert_event(refailed_retry, "release_blocklisted", request_id: 25, at: "2026-01-02 01:00:00")
    insert_override(request_id: 26, search_result_id: retried_as_other_torrent, at: "2026-01-02 00:00:00")
    rows[:other_torrent_retry] = insert_download(request_id: 26, external_id: "c" * 40, not_found_count: 3, search_result_id: retried_as_other_torrent, at: "2026-01-02 00:00:01")
    insert_event(rows[:refreshed_after_override], "release_blocklisted", request_id: 27, at: "2026-01-01 01:00:00", search_result_id: refreshed_away_id)
    insert_override(request_id: 27, search_result_id: refreshed_away_id, at: "2026-01-02 00:00:00")

    run_migration

    assert_equal(
      {
        overridden_monitor_miss: nil,
        overridden_blocklisted: nil,
        refailed_after_override: "3" * 40,
        failed_after_override: "4" * 40,
        other_release_overridden: "5" * 40,
        retry_refailed_after_override: nil,
        retry_got_other_torrent: nil,
        refreshed_after_override: nil,
        other_torrent_retry: "c" * 40
      },
      rows.transform_values { |id| blocklisted_hash(id) }
    )
  end

  test "does not infer a legacy block when a later override survives without the failure link" do
    orphaned_failure = insert_download(
      request_id: 30, external_id: HASH, not_found_count: 3, at: "2026-01-01 00:00:00"
    )
    unaffected_failure = insert_download(
      request_id: 31, external_id: HASH, not_found_count: 3, at: "2026-01-01 00:00:00"
    )
    insert_override(request_id: 30, search_result_id: 9_000, at: "2026-01-12 00:00:00")

    run_migration

    assert_nil blocklisted_hash(orphaned_failure)
    assert_equal HASH, blocklisted_hash(unaffected_failure)
  end

  private

  def insert_override(request_id:, search_result_id:, at:)
    @connection.execute(<<~SQL.squish)
      INSERT INTO request_events (request_id, event_type, details, created_at)
      VALUES (#{Integer(request_id)}, 'blocklist_overridden',
        #{@connection.quote({ search_result_id: search_result_id, title: "Release" }.to_json)}, #{@connection.quote(at)})
    SQL
  end

  def insert_search_result(blocklisted:, at: "2026-01-01 12:00:00")
    @connection.execute(<<~SQL.squish)
      INSERT INTO search_results (request_id, blocklisted_at)
      VALUES (1, #{blocklisted ? @connection.quote(at) : "NULL"})
    SQL
    id = @connection.select_value("SELECT MAX(id) FROM search_results").to_i
    @connection.execute("UPDATE search_results SET guid = 'guid-#{id}' WHERE id = #{id}")
    id
  end

  def insert_event(download_id, event_type, request_id: nil, at: "2026-01-01 01:00:00", search_result_id: nil)
    details = { search_result_id: search_result_id }.compact.to_json
    @connection.execute(<<~SQL.squish)
      INSERT INTO request_events (request_id, download_id, event_type, details, created_at)
      VALUES (#{@connection.quote(request_id)}, #{Integer(download_id)}, #{@connection.quote(event_type)}, #{@connection.quote(details)}, #{@connection.quote(at)})
    SQL
  end

  def insert_download(request_id:, external_id:, status: "failed", download_type: "torrent", not_found_count: 0, search_result_id: nil, at: "2026-01-01 00:00:00")
    columns = {
      "created_at" => at,
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
