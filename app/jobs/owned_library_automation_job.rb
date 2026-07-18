# frozen_string_literal: true

class OwnedLibraryAutomationJob < ApplicationJob
  WATCHDOG_BATCH_SIZE = 25
  CONCURRENCY_LEASE = 10.minutes

  queue_as :default
  limits_concurrency to: 1,
    key: "owned-library-automation",
    duration: CONCURRENCY_LEASE,
    on_conflict: :discard

  class << self
    def backup_job_pending?(owned_media_import_id)
      return false unless solid_queue_adapter?

      SolidQueue::Job
        .where(class_name: OwnedMediaBackupJob.name, finished_at: nil)
        .where.missing(:failed_execution)
        .any? do |job|
          Array(job.arguments["arguments"]).first.to_i == owned_media_import_id.to_i
        end
    rescue ActiveRecord::ActiveRecordError, NameError
      # When the queue cannot be inspected, avoiding a duplicate backup is
      # safer than trying to repair it blindly. The next recurring run can retry.
      true
    end

    private

    def solid_queue_adapter?
      ActiveJob::Base.queue_adapter.class.name == "ActiveJob::QueueAdapters::SolidQueueAdapter"
    end
  end

  def perform
    enqueue_due_syncs
    dispatch_pending_backlog_backups
    recover_stale_imports
  end

  private

  def enqueue_due_syncs
    now = Time.current
    OwnedLibraryConnection.scheduled_sync_due(now).find_each do |connection|
      OwnedLibrarySyncRequest.call(connection: connection, mode: :scheduled, now: now)
    rescue StandardError => e
      Rails.logger.error(
        "[AudibleBackup] Scheduled sync dispatch failed for connection ##{connection.id}: #{e.class}"
      )
    end
  end

  def recover_stale_imports
    OwnedMediaImport.active
      .where("owned_media_imports.updated_at <= ?", OwnedMediaImport::RECOVERY_GRACE_PERIOD.ago)
      .order(:updated_at, :id)
      .limit(WATCHDOG_BATCH_SIZE)
      .each { |media_import| recover_import(media_import) }
  end

  def dispatch_pending_backlog_backups
    OwnedLibraryBacklogBackup.pending_connection_ids.each do |connection_id|
      connection = OwnedLibraryConnection.find_by(id: connection_id)
      OwnedLibraryBacklogBackup.dispatch_next(connection: connection) if connection
    rescue StandardError => e
      Rails.logger.error(
        "[AudibleBackup] Backlog dispatch failed for connection ##{connection_id}: #{e.class}"
      )
    end
  end

  def recover_import(media_import)
    return if self.class.backup_job_pending?(media_import.id)

    poll_token = media_import.with_lock do
      media_import.reload
      next unless media_import.recoverable?
      next if self.class.backup_job_pending?(media_import.id)

      token = OwnedMediaImport.generate_poll_token
      media_import.update!(poll_token: token)
      token
    end
    return unless poll_token

    job = OwnedMediaBackupJob.perform_later(media_import.id, poll_token)
    return if job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?

    Rails.logger.error(
      "[AudibleBackup] Failed to enqueue automatic backup recovery for import ##{media_import.id}"
    )
  rescue StandardError => e
    Rails.logger.error(
      "[AudibleBackup] Automatic backup recovery failed for import ##{media_import.id}: #{e.class}"
    )
  end
end
