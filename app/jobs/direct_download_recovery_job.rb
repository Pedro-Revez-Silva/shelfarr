# frozen_string_literal: true

class DirectDownloadRecoveryJob < ApplicationJob
  queue_as :default

  def perform
    Download.where.not(direct_staging_path: nil).find_each do |download|
      DirectDownloadFileService.reconcile!(download)
    rescue => error
      Rails.logger.warn(
        "[DirectDownloadRecoveryJob] Could not reconcile download #{download.id}: #{error.class}"
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
