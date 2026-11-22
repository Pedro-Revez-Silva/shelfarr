# frozen_string_literal: true

class AddBlocklistedInfoHashToDownloads < ActiveRecord::Migration[8.1]
  DOWNLOAD_FAILED = 4
  MONITOR_NOT_FOUND_THRESHOLD = 3

  def up
    add_column :downloads, :blocklisted_info_hash, :string
    add_column :downloads, :blocklisted_release_guid, :string
    backfill_failed_torrent_releases
  end

  def down
    remove_column :downloads, :blocklisted_release_guid
    remove_column :downloads, :blocklisted_info_hash
  end

  private

  def backfill_failed_torrent_releases
    execute <<~SQL.squish
      UPDATE downloads
      SET blocklisted_info_hash = lower(external_id),
          blocklisted_release_guid = (
            SELECT search_results.guid FROM search_results
            WHERE search_results.id = downloads.search_result_id
          )
      WHERE status = #{DOWNLOAD_FAILED}
        AND download_type = 'torrent'
        AND length(external_id) = 40
        AND lower(external_id) NOT GLOB '*[^0-9a-f]*'
        AND (
          not_found_count >= #{MONITOR_NOT_FOUND_THRESHOLD}
          OR EXISTS (
            SELECT 1 FROM request_events
            WHERE request_events.download_id = downloads.id
              AND request_events.event_type = 'release_blocklisted'
          )
          OR (
            EXISTS (
              SELECT 1 FROM search_results
              WHERE search_results.id = downloads.search_result_id
                AND search_results.blocklisted_at IS NOT NULL
            )
            AND NOT EXISTS (
              SELECT 1 FROM downloads AS later_attempts
              WHERE later_attempts.search_result_id = downloads.search_result_id
                AND later_attempts.id > downloads.id
            )
          )
        )
        AND NOT EXISTS (
          SELECT 1 FROM downloads AS later_downloads
          WHERE later_downloads.request_id = downloads.request_id
            AND later_downloads.id > downloads.id
            AND lower(later_downloads.external_id) = lower(downloads.external_id)
        )
    SQL
  end
end
