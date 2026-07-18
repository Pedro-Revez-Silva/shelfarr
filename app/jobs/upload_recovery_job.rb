# frozen_string_literal: true

# Durable watchdog for manual uploads whose processing worker was killed.
# Audible/Libation uploads are deliberately excluded because their
# OwnedMediaBackupJob polling chain owns recovery and filesystem reconciliation.
class UploadRecoveryJob < ApplicationJob
  RECOVERY_GRACE_PERIOD = 30.minutes
  RECOVERY_DISPATCH_DELAY = 5.seconds
  BATCH_SIZE = 25
  JOB_CONCURRENCY_LEASE = 10.minutes

  queue_as :default
  limits_concurrency to: 1,
    key: "upload-recovery",
    duration: JOB_CONCURRENCY_LEASE,
    on_conflict: :discard

  class << self
    def processing_job_pending?(upload_id)
      return true unless solid_queue_adapter?

      SolidQueue::Job
        .where(class_name: UploadProcessingJob.name, finished_at: nil)
        .where.missing(:failed_execution)
        .any? do |job|
          Array(job.arguments["arguments"]).first.to_i == upload_id.to_i
        end
    rescue StandardError => error
      # Queue state is the guard against resetting a live worker. If it cannot
      # be inspected, wait for the next recurring pass instead of risking two
      # filesystem writers.
      Rails.logger.warn(
        "[UploadRecoveryJob] Could not inspect jobs for upload ##{upload_id}: #{error.class}"
      )
      true
    end

    private

    def solid_queue_adapter?
      ActiveJob::Base.queue_adapter.class.name == "ActiveJob::QueueAdapters::SolidQueueAdapter"
    end
  end

  def perform
    cleanup_completed_sources
    stale_ordinary_uploads.each { |upload| recover(upload) }
  end

  private

  def cleanup_completed_sources
    Upload.completed
      .where.not(cleanup_source_path: nil)
      .order(:updated_at, :id)
      .limit(BATCH_SIZE)
      .each do |upload|
        cleaned = if UploadZipImportFileService.archive_upload?(upload)
          UploadZipImportFileService.cleanup_completed_source!(upload)
        else
          UploadImportFileService.cleanup_completed_source!(upload)
        end
        next if cleaned

        Rails.logger.warn(
          "[UploadRecoveryJob] Completed source cleanup remains pending for upload ##{upload.id}"
        )
      rescue StandardError => error
        Rails.logger.error(
          "[UploadRecoveryJob] Completed source cleanup failed for upload ##{upload.id}: #{error.class}"
        )
      end
  end

  def stale_ordinary_uploads
    Upload.where(status: [ :pending, :processing ])
      .where("uploads.updated_at <= ?", RECOVERY_GRACE_PERIOD.ago)
      .where.not(
        id: OwnedMediaImport.where.not(upload_id: nil).select(:upload_id)
      )
      .order(:updated_at, :id)
      .limit(BATCH_SIZE)
  end

  def recover(upload)
    dispatch = upload.with_lock do
      upload.reload
      next false unless upload.pending? || upload.processing?
      next false unless upload.updated_at <= RECOVERY_GRACE_PERIOD.ago
      next false if OwnedMediaImport.exists?(upload_id: upload.id)
      next false if self.class.processing_job_pending?(upload.id)

      # Commit the claim before dispatch. A queued job can therefore never run
      # against the old processing state and no-op immediately before this
      # transaction changes it to pending. If the process is killed in the
      # short post-commit enqueue gap, the stale-pending scan retries it after
      # the grace period instead of stranding it forever.
      upload.update!(status: :pending, error_message: nil, updated_at: Time.current)
      true
    end
    return unless dispatch

    job = UploadProcessingJob
      .set(wait: RECOVERY_DISPATCH_DELAY)
      .perform_later(upload.id)
    unless job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?
      Rails.logger.error(
        "[UploadRecoveryJob] Could not enqueue recovery for upload ##{upload.id}; " \
          "the pending-upload watchdog will retry it"
      )
    end
  rescue StandardError => error
    Rails.logger.error(
      "[UploadRecoveryJob] Recovery failed for upload ##{upload.id}: #{error.class}"
    )
  end
end
