# frozen_string_literal: true

class DirectDownloadRecoveryJob < ApplicationJob
  queue_as :default

  def perform
    tracked_downloads = Download.where.not(direct_staging_path: nil)
      .or(Download.where.not(direct_reservation_token: nil))
    tracked_downloads.find_each do |download|
      DirectDownloadFileService.reconcile!(download)
    rescue => error
      Rails.logger.warn(
        "[DirectDownloadRecoveryJob] Could not reconcile download #{download.id}: #{error.class}"
      )
    end

    cleared = DirectDownloadFileService.reconcile_orphaned_reservations!
    if cleared.positive?
      Rails.logger.info(
        "[DirectDownloadRecoveryJob] Released #{cleared} orphaned direct-download reservations"
      )
    end

    DirectDownloadFileService.output_roots.each do |root|
      removed = DirectDownloadFileService.cleanup_orphans!(root: root)
      if removed.positive?
        Rails.logger.info(
          "[DirectDownloadRecoveryJob] Removed #{removed} orphaned direct-download staging directories"
        )
      end
    end
  end
end
