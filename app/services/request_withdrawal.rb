# frozen_string_literal: true

class RequestWithdrawal
  def self.call(request, remove_torrents:)
    new(request, remove_torrents: remove_torrents).call
  end

  def initialize(request, remove_torrents:)
    @request = request
    @remove_torrents = remove_torrents
  end

  def call
    return stop_for_direct_recovery if @request.direct_acquisition_recovery_pending?

    @request.claim_destructive_cancellation!
    remove_torrents if @remove_torrents
    book = @request.book
    @request.destroy!
    ActivityTracker.track("request.cancelled", trackable: @request)
    book.destroy if book.requests.empty? && !book.acquisition_blocked?
    :removed
  end

  private

  def stop_for_direct_recovery
    @request.cancel!(allow_direct_recovery: true)
    DirectDownloadRecoveryJob.perform_later
    :awaiting_direct_recovery
  end

  def remove_torrents
    @request.downloads.each do |download|
      next unless download.external_id.present? && download.download_client.present?

      begin
        download.download_client.adapter.remove_torrent(download.external_id, delete_files: false)
        Rails.logger.info "[RequestWithdrawal] Removed torrent for download ##{download.id}"
      rescue DownloadClients::Base::Error => e
        Rails.logger.warn("[RequestWithdrawal] Failed to remove torrent for download ##{download.id}: #{e.class}")
      end
    end
  end
end
