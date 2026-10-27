# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261026120000_record_download_dispatch_outcomes")

class RecordDownloadDispatchOutcomesTest < ActiveSupport::TestCase
  class IsolatedMigrationRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    IsolatedMigrationRecord.establish_connection(adapter: "sqlite3", database: ":memory:")
    @connection = IsolatedMigrationRecord.connection
    @connection.create_table(:requests) do |table|
      table.integer :status, null: false
    end
    @connection.create_table(:downloads) do |table|
      table.integer :request_id
      table.integer :status, null: false, default: 0
      table.integer :search_result_id
      table.string :post_processing_cleanup_state
      table.string :post_processing_job_id
      RecordDownloadDispatchOutcomes::DIRECT_RECOVERY_COLUMNS.each do |column|
        table.string column
      end
    end
    @connection.create_table(:search_results) do |table|
      table.integer :request_id
      table.integer :status, null: false, default: 0
    end
    @connection.create_table(:request_events) do |table|
      table.integer :download_id
      table.string :event_type, null: false
      table.text :details
      table.datetime :created_at, null: false
    end
  end

  teardown do
    IsolatedMigrationRecord.remove_connection
  end

  test "releases unclaimed completed downloads on non-acquiring requests and keeps live claims" do
    rows = {}

    not_found = insert_request("not_found")
    rows["not_found"] = insert_download(request_id: not_found)
    rows["not_found_blank_cleanup"] = insert_download(request_id: not_found, cleanup: "")
    rows["not_found_blank_import_owner"] = insert_download(request_id: not_found, job_id: "")
    rows["not_found_import_owner"] = insert_download(request_id: not_found, job_id: "import-owner")
    rows["not_found_cleanup"] = insert_download(request_id: not_found, cleanup: '{"version":1}')
    rows["not_found_direct_recovery"] = insert_download(
      request_id: not_found,
      direct: { "direct_staging_path" => "/ebooks/.shelfarr-staging/direct-downloads/recovery/download" }
    )
    rows["not_found_still_downloading"] = insert_download(request_id: not_found, download_status: "downloading")

    %w[pending searching awaiting_purchase].each do |status|
      rows[status] = insert_download(request_id: insert_request(status))
    end

    failed = insert_request("failed")
    rows["failed"] = insert_download(request_id: failed)
    rows["failed_blank_import_owner"] = insert_download(request_id: failed, job_id: "")
    rows["failed_import_owner"] = insert_download(request_id: failed, job_id: "import-owner")
    rows["failed_cleanup"] = insert_download(request_id: failed, cleanup: '{"version":1}')
    rows["failed_direct_recovery"] = insert_download(
      request_id: failed,
      direct: { "direct_reservation_token" => "reserved" }
    )

    completed = insert_request("completed")
    rows["completed"] = insert_download(request_id: completed)
    rows["completed_with_import_owner"] = insert_download(request_id: completed, job_id: "legacy-owner")
    rows["completed_blank_cleanup"] = insert_download(request_id: completed, cleanup: "")
    rows["completed_cleanup"] = insert_download(request_id: completed, cleanup: '{"version":1}')
    rows["completed_direct_recovery"] = insert_download(
      request_id: completed,
      direct: { "direct_destination_path" => "/ebooks/recovery/book.epub" }
    )

    rows["downloading_request"] = insert_download(request_id: insert_request("downloading"))
    processing = insert_request("processing")
    rows["processing_request"] = insert_download(request_id: processing)
    rows["processing_with_import_owner"] = insert_download(request_id: processing, job_id: "import-owner")

    rows["orphan"] = insert_download(request_id: 0)
    rows["orphan_with_import_owner"] = insert_download(request_id: 0, job_id: "orphan-import")

    run_migration

    %w[
      not_found
      not_found_blank_cleanup
      not_found_blank_import_owner
      pending
      searching
      awaiting_purchase
      failed
      failed_blank_import_owner
      completed
      completed_with_import_owner
      completed_blank_cleanup
      orphan
      orphan_with_import_owner
    ].each do |label|
      assert_not_nil release_timestamp(rows.fetch(label)), "#{label} should release its client id"
    end

    %w[
      not_found_import_owner
      not_found_cleanup
      not_found_direct_recovery
      not_found_still_downloading
      failed_import_owner
      failed_cleanup
      failed_direct_recovery
      completed_cleanup
      completed_direct_recovery
      downloading_request
      processing_request
      processing_with_import_owner
    ].each do |label|
      assert_nil release_timestamp(rows.fetch(label)), "#{label} should keep its client id"
    end
  end

  test "releases an unclaimed completed download superseded by a queued replacement" do
    rows = {}

    downloading = insert_request("downloading")
    rows["superseded"] = insert_download(request_id: downloading)
    rows["superseded_blank_import_owner"] = insert_download(request_id: downloading, job_id: "")
    rows["superseded_blank_cleanup"] = insert_download(request_id: downloading, cleanup: "")
    rows["queued_replacement"] = insert_download(request_id: downloading, download_status: "queued")

    claimed_by_download = insert_request("downloading")
    rows["superseded_by_downloading"] = insert_download(request_id: claimed_by_download)
    rows["downloading_replacement"] = insert_download(request_id: claimed_by_download, download_status: "downloading")

    paused = insert_request("downloading")
    rows["superseded_by_paused"] = insert_download(request_id: paused)
    rows["paused_replacement"] = insert_download(request_id: paused, download_status: "paused")

    processing = insert_request("processing")
    rows["processing_superseded"] = insert_download(request_id: processing)
    rows["processing_queued_replacement"] = insert_download(request_id: processing, download_status: "queued")

    importing = insert_request("downloading")
    rows["import_owner"] = insert_download(request_id: importing, job_id: "import-owner")
    rows["import_owner_replacement"] = insert_download(request_id: importing, download_status: "queued")

    cleaning = insert_request("downloading")
    rows["cleanup_owner"] = insert_download(request_id: cleaning, cleanup: '{"version":1}')
    rows["cleanup_replacement"] = insert_download(request_id: cleaning, download_status: "queued")

    recovering = insert_request("downloading")
    rows["direct_owner"] = insert_download(
      request_id: recovering,
      direct: { "direct_staging_path" => "/ebooks/.shelfarr-staging/direct-downloads/recovery/download" }
    )
    rows["direct_replacement"] = insert_download(request_id: recovering, download_status: "queued")

    failed_sibling = insert_request("downloading")
    rows["failed_sibling_owner"] = insert_download(request_id: failed_sibling)
    rows["failed_sibling"] = insert_download(request_id: failed_sibling, download_status: "failed")

    other_request = insert_request("downloading")
    rows["other_request_owner"] = insert_download(request_id: other_request)
    rows["other_request_queued"] = insert_download(request_id: insert_request("downloading"), download_status: "queued")

    older_queued = insert_request("downloading")
    rows["older_queued"] = insert_download(request_id: older_queued, download_status: "queued")
    rows["newer_completed"] = insert_download(request_id: older_queued)

    run_migration

    %w[
      superseded
      superseded_blank_import_owner
      superseded_blank_cleanup
      superseded_by_downloading
      superseded_by_paused
      processing_superseded
    ].each do |label|
      assert_not_nil release_timestamp(rows.fetch(label)), "#{label} should release its client id"
    end

    %w[
      queued_replacement
      downloading_replacement
      paused_replacement
      processing_queued_replacement
      import_owner
      import_owner_replacement
      cleanup_owner
      cleanup_replacement
      direct_owner
      direct_replacement
      failed_sibling_owner
      failed_sibling
      other_request_owner
      other_request_queued
      older_queued
      newer_completed
    ].each do |label|
      assert_nil release_timestamp(rows.fetch(label)), "#{label} should keep its client id"
    end
  end

  test "releases an unclaimed completed download superseded by a completed selected replacement" do
    rows = {}

    processing = insert_request("processing")
    rows["superseded"] = insert_download(
      request_id: processing,
      search_result_id: insert_search_result(processing, "rejected")
    )
    rows["selected_replacement"] = insert_download(
      request_id: processing,
      job_id: "import-owner",
      search_result_id: insert_search_result(processing, "selected")
    )

    blank = insert_request("processing")
    rows["superseded_blank_cleanup"] = insert_download(
      request_id: blank,
      cleanup: "",
      search_result_id: insert_search_result(blank, "rejected")
    )
    rows["blank_cleanup_replacement"] = insert_download(
      request_id: blank,
      search_result_id: insert_search_result(blank, "selected")
    )

    claimed_import = insert_request("processing")
    rows["import_owner"] = insert_download(
      request_id: claimed_import,
      job_id: "import-owner",
      search_result_id: insert_search_result(claimed_import, "rejected")
    )
    rows["import_owner_replacement"] = insert_download(
      request_id: claimed_import,
      job_id: "replacement-owner",
      search_result_id: insert_search_result(claimed_import, "selected")
    )

    cleaning = insert_request("downloading")
    rows["cleanup_owner"] = insert_download(
      request_id: cleaning,
      cleanup: '{"version":1}',
      search_result_id: insert_search_result(cleaning, "rejected")
    )
    rows["cleanup_replacement"] = insert_download(
      request_id: cleaning,
      job_id: "import-owner",
      search_result_id: insert_search_result(cleaning, "selected")
    )

    recovering = insert_request("downloading")
    rows["direct_owner"] = insert_download(
      request_id: recovering,
      direct: { "direct_staging_path" => "/ebooks/.shelfarr-staging/direct-downloads/recovery/download" },
      search_result_id: insert_search_result(recovering, "rejected")
    )
    rows["direct_replacement"] = insert_download(
      request_id: recovering,
      job_id: "import-owner",
      search_result_id: insert_search_result(recovering, "selected")
    )

    still_selected = insert_request("downloading")
    rows["selected_owner"] = insert_download(
      request_id: still_selected,
      search_result_id: insert_search_result(still_selected, "selected")
    )
    rows["later_unselected_completed"] = insert_download(
      request_id: still_selected,
      search_result_id: insert_search_result(still_selected, "rejected")
    )

    legacy = insert_request("processing")
    rows["legacy_without_result"] = insert_download(request_id: legacy)
    rows["legacy_replacement"] = insert_download(
      request_id: legacy,
      job_id: "import-owner",
      search_result_id: insert_search_result(legacy, "selected")
    )

    other = insert_request("processing")
    rows["other_request_owner"] = insert_download(
      request_id: other,
      search_result_id: insert_search_result(other, "rejected")
    )
    unrelated = insert_request("processing")
    rows["unrelated_completed"] = insert_download(
      request_id: unrelated,
      job_id: "import-owner",
      search_result_id: insert_search_result(unrelated, "selected")
    )

    run_migration

    %w[superseded superseded_blank_cleanup].each do |label|
      assert_not_nil release_timestamp(rows.fetch(label)), "#{label} should release its client id"
    end

    %w[
      selected_replacement
      blank_cleanup_replacement
      import_owner
      import_owner_replacement
      cleanup_owner
      cleanup_replacement
      direct_owner
      direct_replacement
      selected_owner
      later_unselected_completed
      legacy_without_result
      legacy_replacement
      other_request_owner
      unrelated_completed
    ].each do |label|
      assert_nil release_timestamp(rows.fetch(label)), "#{label} should keep its client id"
    end
  end

  private

  def insert_request(status)
    @connection.execute(<<~SQL.squish)
      INSERT INTO requests (status) VALUES (#{Integer(Request.statuses.fetch(status))})
    SQL
    @connection.select_value("SELECT MAX(id) FROM requests").to_i
  end

  def insert_search_result(request_id, status)
    @connection.execute(<<~SQL.squish)
      INSERT INTO search_results (request_id, status)
      VALUES (#{Integer(request_id)}, #{Integer(SearchResult.statuses.fetch(status))})
    SQL
    @connection.select_value("SELECT MAX(id) FROM search_results").to_i
  end

  def insert_download(request_id:, download_status: "completed", cleanup: nil, job_id: nil, direct: {}, search_result_id: nil)
    columns = {
      "request_id" => request_id,
      "status" => Download.statuses.fetch(download_status),
      "search_result_id" => search_result_id,
      "post_processing_cleanup_state" => cleanup,
      "post_processing_job_id" => job_id
    }
    RecordDownloadDispatchOutcomes::DIRECT_RECOVERY_COLUMNS.each do |column|
      columns[column] = direct[column]
    end
    names = columns.keys
    values = names.map { |name| @connection.quote(columns[name]) }
    @connection.execute("INSERT INTO downloads (#{names.join(", ")}) VALUES (#{values.join(", ")})")
    @connection.select_value("SELECT MAX(id) FROM downloads").to_i
  end

  def release_timestamp(id)
    @connection.select_value(
      "SELECT external_id_released_at FROM downloads WHERE id = #{Integer(id)}"
    )
  end

  def run_migration
    migration = RecordDownloadDispatchOutcomes.new
    migration.verbose = false
    connection = @connection
    migration.define_singleton_method(:connection) { connection }
    migration.up
  end
end
