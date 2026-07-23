# frozen_string_literal: true

# Recovers the two durable delivery gaps around PostProcessingJob:
#
# * DownloadMonitorJob committed a completed Download but was killed before it
#   could enqueue post-processing.
# * PostProcessingJob claimed the Download (or published only part of an
#   idempotent import) and its worker was killed before atomic finalization.
#
# The Download owner is transferred before enqueue. If that enqueue itself is
# interrupted, a later pass can transfer the stale owner again. Solid Queue is
# inspected before every transfer so a slow or scheduled live worker is never
# superseded merely because the application row has not changed recently.
class PostProcessingRecoveryJob < ApplicationJob
  RECOVERY_GRACE_PERIOD = 30.minutes
  RECOVERY_DISPATCH_DELAY = 5.seconds
  BATCH_SIZE = 25
  JOB_CONCURRENCY_LEASE = 10.minutes

  queue_as :default
  limits_concurrency to: 1,
    key: "post-processing-recovery",
    duration: JOB_CONCURRENCY_LEASE,
    on_conflict: :discard

  class << self
    def processing_job_pending?(download_id)
      # Production uses Solid Queue. For another adapter, queue liveness cannot
      # be proven; fail closed instead of risking two filesystem publishers.
      return true unless solid_queue_adapter?

      SolidQueue::Job
        .where(class_name: PostProcessingJob.name, finished_at: nil)
        .where.missing(:failed_execution)
        .any? do |job|
          Array(job.arguments["arguments"]).first.to_i == download_id.to_i
        end
    rescue StandardError => error
      Rails.logger.warn(
        "[PostProcessingRecoveryJob] Could not inspect jobs for download ##{download_id}: #{error.class}"
      )
      true
    end

    private

    def solid_queue_adapter?
      ActiveJob::Base.queue_adapter.class.name ==
        "ActiveJob::QueueAdapters::SolidQueueAdapter"
    end
  end

  def perform
    cleanup_downloads.each { |download| recover_source_cleanup(download) }
    stale_downloads.each { |download| recover(download) }
  end

  private

  def stale_downloads
    Download.completed
      .joins(:request)
      .where(requests: { status: [ Request.statuses[:downloading], Request.statuses[:processing] ] })
      .where(requests: { attention_needed: false })
      .where("downloads.updated_at <= ?", RECOVERY_GRACE_PERIOD.ago)
      .order(:updated_at, :id)
      .limit(BATCH_SIZE)
  end

  def cleanup_downloads
    Download.completed
      .joins(:request)
      .where(requests: { status: Request.statuses[:completed] })
      .where.not(post_processing_cleanup_state: [ nil, "" ])
      .order(:updated_at, :id)
      .limit(BATCH_SIZE)
  end

  def recover_source_cleanup(download)
    cleanup_state = download.post_processing_cleanup_state
    payload = JSON.parse(cleanup_state)
    source_snapshot = FileCopyService.deserialize_file_snapshot(payload.fetch("source"))
    destination_snapshot = FileCopyService.deserialize_file_snapshot(payload.fetch("destination"))
    removed = FileCopyService.remove_source_file(
      source_snapshot,
      destination_snapshot: destination_snapshot
    )
    unless removed
      Rails.logger.warn(
        "[PostProcessingRecoveryJob] Source cleanup was no longer safe for download ##{download.id}; it was retained"
      )
    end
    if !removed && FileCopyService.source_file_quarantined?(source_snapshot)
      Download.where(
        id: download.id,
        post_processing_cleanup_state: cleanup_state
      ).update_all(updated_at: Time.current)
      return
    end

    Download.where(
      id: download.id,
      post_processing_cleanup_state: cleanup_state
    ).update_all(post_processing_cleanup_state: nil, updated_at: Time.current)
  rescue StandardError => error
    Rails.logger.error(
      "[PostProcessingRecoveryJob] Source cleanup recovery failed for download ##{download.id}: #{error.class}"
    )
    Download.where(id: download.id).update_all(updated_at: Time.current)
  end

  def recover(download)
    if self.class.processing_job_pending?(download.id)
      download.touch
      return
    end

    expected_owner = download.post_processing_job_id.presence
    replacement = PostProcessingJob.new(download.id, 0, expected_owner)
    claimed = download.request.with_acquisition_transition_lock do |request|
      download.reload
      next false unless download.completed?
      next false unless request.downloading? || request.processing?
      next false if request.upload_cancellation_blocked?
      next false if request.direct_acquisition_recovery_pending?
      next false unless same_owner?(download.post_processing_job_id, expected_owner)
      next false if self.class.processing_job_pending?(download.id)

      updated = Download.where(id: download.id)
      updated = expected_owner.present? ?
        updated.where(post_processing_job_id: expected_owner) :
        updated.where(post_processing_job_id: [ nil, "" ])
      updated.update_all(
        post_processing_job_id: replacement.job_id,
        updated_at: Time.current
      ) == 1
    end
    return unless claimed

    unless replacement.enqueue(wait: RECOVERY_DISPATCH_DELAY)
      Rails.logger.error(
        "[PostProcessingRecoveryJob] Could not enqueue recovery for download ##{download.id}; " \
          "the durable owner will be retried"
      )
    end
  rescue ActiveRecord::RecordNotFound
    nil
  rescue StandardError => error
    Rails.logger.error(
      "[PostProcessingRecoveryJob] Recovery failed for download ##{download.id}: #{error.class}"
    )
  end

  def same_owner?(current, expected)
    current.to_s == expected.to_s
  end
end
