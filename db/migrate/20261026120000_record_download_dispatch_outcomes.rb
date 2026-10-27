# frozen_string_literal: true

class RecordDownloadDispatchOutcomes < ActiveRecord::Migration[8.1]
  DOWNLOAD_COMPLETED = 3
  REQUEST_DOWNLOADING = 3
  REQUEST_PROCESSING = 4
  REQUEST_COMPLETED = 5

  DIRECT_RECOVERY_COLUMNS = %w[
    direct_reservation_token
    direct_staging_path
    direct_staging_device
    direct_staging_inode
    direct_staging_parent_device
    direct_staging_parent_inode
    direct_destination_path
    direct_book_path
    direct_output_root
    direct_output_root_device
    direct_output_root_inode
    direct_publication_kind
    direct_content_manifest
  ].freeze

  def up
    add_column :downloads, :external_id_released_at, :datetime
    add_column :downloads, :configuration_failure, :boolean, default: false, null: false

    # Request status and diagnostic events can change after the download is stored.
    release_retired_external_ids
    backfill_configuration_failures
  end

  def down
    remove_column :downloads, :configuration_failure
    remove_column :downloads, :external_id_released_at
  end

  private

  # Recovery imports a completed download only while its request is still
  # downloading or processing. A later not_found (or any other non-acquiring
  # state) must not keep an unclaimed client id reserved.
  def release_retired_external_ids
    direct_absent = DIRECT_RECOVERY_COLUMNS.map { |column| "downloads.#{column} IS NULL" }.join(" AND ")
    execute <<~SQL.squish
      UPDATE downloads
      SET external_id_released_at = CURRENT_TIMESTAMP
      WHERE downloads.status = #{DOWNLOAD_COMPLETED}
        AND (downloads.post_processing_cleanup_state IS NULL OR downloads.post_processing_cleanup_state = '')
        AND #{direct_absent}
        AND (
          NOT EXISTS (
            SELECT 1 FROM requests WHERE requests.id = downloads.request_id
          )
          OR EXISTS (
            SELECT 1 FROM requests
            WHERE requests.id = downloads.request_id
              AND (
                requests.status = #{REQUEST_COMPLETED}
                OR (
                  requests.status NOT IN (#{REQUEST_DOWNLOADING}, #{REQUEST_PROCESSING})
                  AND (downloads.post_processing_job_id IS NULL OR downloads.post_processing_job_id = '')
                )
              )
          )
        )
    SQL
  end

  def backfill_configuration_failures
    execute <<~SQL.squish
      UPDATE downloads
      SET configuration_failure = 1
      WHERE id IN (
        SELECT latest.download_id
        FROM (
          SELECT download_id,
                 details,
                 ROW_NUMBER() OVER (
                   PARTITION BY download_id
                   ORDER BY created_at DESC, id DESC
                 ) AS event_rank
          FROM request_events
          WHERE event_type = 'dispatch_failed'
            AND download_id IS NOT NULL
        ) AS latest
        WHERE latest.event_rank = 1
          AND json_extract(latest.details, '$.configuration_error') = 1
      )
    SQL
  end
end
