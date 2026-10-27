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
      table.string :post_processing_cleanup_state
      table.string :post_processing_job_id
      RecordDownloadDispatchOutcomes::DIRECT_RECOVERY_COLUMNS.each do |column|
        table.string column
      end
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

  private

  def insert_request(status)
    @connection.execute(<<~SQL.squish)
      INSERT INTO requests (status) VALUES (#{Integer(Request.statuses.fetch(status))})
    SQL
    @connection.select_value("SELECT MAX(id) FROM requests").to_i
  end

  def insert_download(request_id:, download_status: "completed", cleanup: nil, job_id: nil, direct: {})
    columns = {
      "request_id" => request_id,
      "status" => Download.statuses.fetch(download_status),
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
