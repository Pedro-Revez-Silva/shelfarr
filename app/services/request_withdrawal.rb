# frozen_string_literal: true

class RequestWithdrawal
  ClientJob = Data.define(:download_id, :download_client_id, :external_id)
  Facts = Data.define(:client_jobs, :dispatch_in_progress)
  REOPENED = "This request was started again while it was being cancelled, so it was kept. Check it and cancel it again if you still want to."

  def self.call(request, remove_client_jobs:, allow_direct_recovery: true, &admission)
    new(request, remove_client_jobs: remove_client_jobs, allow_direct_recovery: allow_direct_recovery).call(&admission)
  end

  def self.facts(request)
    downloads = request.downloads.includes(:download_client).to_a
    Facts.new(client_jobs(request, downloads), downloads.any? { |download| download.downloading? && download.external_id.blank? })
  end

  def self.client_jobs(request, downloads = request.downloads.includes(:download_client).to_a)
    downloads
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

  def initialize(request, remove_client_jobs:, allow_direct_recovery:)
    @request = request
    @remove_client_jobs = remove_client_jobs
    @allow_direct_recovery = allow_direct_recovery
  end

  def call(&admission)
    return stop_for_direct_recovery(&admission) if @allow_direct_recovery && @request.direct_acquisition_recovery_pending?

    @request.claim_destructive_cancellation!(&admission)
    self.class.client_jobs(@request).each { |job| remove_client_job(job) } if @remove_client_jobs
    book = @request.book
    destroy_claimed_request!
    ActivityTracker.track("request.cancelled", trackable: @request)
    book.destroy if book.requests.empty? && !book.acquisition_blocked?
    :removed
  end

  private

  def stop_for_direct_recovery(&admission)
    @request.cancel!(allow_direct_recovery: true, &admission)
    DirectDownloadRecoveryJob.perform_later
    :awaiting_direct_recovery
  end

  def destroy_claimed_request!
    @request.with_acquisition_transition_lock do
      raise Request::CancellationBlockedError, REOPENED unless claimed?

      @request.destroy!
    end
  end

  def claimed?
    @request.failed? && !@request.downloads.where(status: [ :queued, :downloading, :paused ]).exists?
  end

  def remove_client_job(job)
    if Download.current_external_id_owner(job.external_id, download_client_id: job.download_client_id)
      Rails.logger.info "[RequestWithdrawal] Left the client job of download ##{job.download_id}; another request now owns it"
      return
    end

    client = DownloadClient.find_by(id: job.download_client_id)
    return unless client

    client.adapter.remove_torrent(job.external_id, delete_files: false)
    Rails.logger.info "[RequestWithdrawal] Removed torrent for download ##{job.download_id}"
  rescue DownloadClients::Base::Error => e
    Rails.logger.warn("[RequestWithdrawal] Failed to remove torrent for download ##{job.download_id}: #{e.class}")
  end
end
