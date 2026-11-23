# frozen_string_literal: true

class RequestWithdrawal
  ClientJob = Data.define(:download_id, :download_client_id, :external_id)

  def self.call(request, remove_client_jobs:, &admission)
    new(request, remove_client_jobs: remove_client_jobs).call(&admission)
  end

  def self.client_jobs(request)
    request.downloads
      .select { |download| download.external_id.present? && download.download_client.present? }
      .reject { |download| owned_by_another_request?(download, request) }
      .uniq { |download| [ download.download_client_id, download.external_id ] }
      .map { |download| ClientJob.new(download.id, download.download_client_id, download.external_id) }
  end

  def self.owned_by_another_request?(download, request)
    owner = Download.current_external_id_owner(download.external_id, download_client_id: download.download_client_id, except_id: download.id)
    owner.present? && owner.request_id != request.id
  end
  private_class_method :owned_by_another_request?

  def initialize(request, remove_client_jobs:)
    @request = request
    @remove_client_jobs = remove_client_jobs
  end

  def call(&admission)
    return stop_for_direct_recovery(&admission) if @request.direct_acquisition_recovery_pending?

    @request.claim_destructive_cancellation!(&admission)
    jobs = @remove_client_jobs ? self.class.client_jobs(@request) : []
    book = @request.book
    @request.destroy!
    ActivityTracker.track("request.cancelled", trackable: @request)
    jobs.each { |job| remove_client_job(job) }
    book.destroy if book.requests.empty? && !book.acquisition_blocked?
    :removed
  end

  private

  def stop_for_direct_recovery(&admission)
    @request.cancel!(allow_direct_recovery: true, &admission)
    DirectDownloadRecoveryJob.perform_later
    :awaiting_direct_recovery
  end

  def remove_client_job(job)
    if Download.current_external_id_owner(job.external_id, download_client_id: job.download_client_id)
      Rails.logger.info "[RequestWithdrawal] Left the client job of download ##{job.download_id}; another request now owns it"
      return
    end

    DownloadClient.find(job.download_client_id).adapter.remove_torrent(job.external_id, delete_files: false)
    Rails.logger.info "[RequestWithdrawal] Removed torrent for download ##{job.download_id}"
  rescue DownloadClients::Base::Error, ActiveRecord::RecordNotFound => e
    Rails.logger.warn("[RequestWithdrawal] Failed to remove torrent for download ##{job.download_id}: #{e.class}")
  end
end
