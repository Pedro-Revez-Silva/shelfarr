# frozen_string_literal: true

class StaleClientDispatchCleanupJob < ApplicationJob
  class CleanupError < StandardError; end

  SAFE_EXTERNAL_ID = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,254}\z/

  queue_as :default
  retry_on CleanupError, wait: :polynomially_longer, attempts: 5

  def perform(download_client_id, external_id)
    return unless external_id.is_a?(String) && external_id.match?(SAFE_EXTERNAL_ID)

    client_record = DownloadClient.find_by(id: download_client_id)
    return unless client_record

    client = client_record.adapter
    return if client.remove_torrent(external_id, delete_files: true)
    return unless client.torrent_info(external_id)

    raise CleanupError, "Download client still contains stale dispatch"
  rescue CleanupError
    raise
  rescue StandardError => e
    raise CleanupError, "Stale dispatch cleanup failed: #{e.class}"
  end
end
