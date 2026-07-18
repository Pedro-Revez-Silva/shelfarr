# frozen_string_literal: true

class OwnedLibrarySyncRequest
  MODES = %i[manual scheduled].freeze
  ENQUEUED_STATUSES = %i[queued recovery resume].freeze
  ENQUEUE_FAILURE_MESSAGE = "Shelfarr could not queue the Libation sync"

  Result = Struct.new(
    :status,
    :job,
    :request_token,
    :expected_sync_job_id,
    :poll_token,
    keyword_init: true
  ) do
    def enqueued?
      status.in?(ENQUEUED_STATUSES)
    end

    def enqueue_failed?
      status == :enqueue_failed
    end
  end

  def self.call(connection:, mode: :manual, now: Time.current)
    new(connection: connection, mode: mode, now: now).call
  end

  def self.sync_job_pending?(
    connection_id,
    request_token,
    expected_sync_job_id,
    poll_token,
    delivery_job_id
  )
    return false unless ActiveJob::Base.queue_adapter.class.name ==
      "ActiveJob::QueueAdapters::SolidQueueAdapter"

    SolidQueue::Job
      .where(class_name: OwnedLibrarySyncJob.name, finished_at: nil)
      .where.missing(:failed_execution)
      .any? do |job|
        arguments = Array(job.arguments["arguments"])
        next false unless arguments.first.to_i == connection_id.to_i
        next false unless arguments.second.to_s == request_token.to_s

        # A running delivery rotates the connection's poll token before
        # blocking on the companion, so its serialized token is intentionally
        # stale. Its globally unique Active Job ID is the stable liveness proof.
        # A queued handoff has not run yet, and is instead proven by the exact
        # companion-job/poll-token chain it will claim.
        exact_delivery = delivery_job_id.present? &&
          job.active_job_id.to_s == delivery_job_id.to_s
        exact_poll_chain = arguments.third.to_s == expected_sync_job_id.to_s &&
          arguments.fourth.to_s == poll_token.to_s
        exact_delivery || exact_poll_chain
      end
  rescue ActiveRecord::ActiveRecordError, NameError
    # If queue inspection is unavailable, preserving the current claim is
    # safer than amplifying a backlog with replacement deliveries.
    true
  end

  def initialize(connection:, mode: :manual, now: Time.current)
    @connection = connection
    @mode = mode.to_sym
    @now = now
    raise ArgumentError, "Unsupported owned-library sync mode: #{mode}" unless @mode.in?(MODES)
  end

  def call
    result = claim_request
    return result unless result.status.in?(ENQUEUED_STATUSES)

    job = enqueue(result)
    unless enqueue_succeeded?(job)
      mark_enqueue_failed(result)
      advance_scheduled_deadline if scheduled?
      return result.tap { |value| value.status = :enqueue_failed }
    end

    persist_enqueued_delivery(result, job)
    result.tap { |value| value.job = job }
  end

  private

  def claim_request
    connection.with_lock do
      connection.reload
      next result(:disabled) unless connection.enabled?
      if scheduled?
        next result(:scheduled_sync_disabled) unless connection.scheduled_sync_enabled?
        next result(:not_due) unless connection.scheduled_sync_due?(at: now)
      end
      next result(:auth_active) if connection.auth_active?
      next result(:backups_active) if connection.owned_media_imports.active.exists?
      # A manual retry must not supersede a live worker merely because a large
      # companion response or reconciliation has not touched the connection row
      # recently. Solid Queue is the durable source of truth for both manual and
      # scheduled recovery admission.
      if connection.sync_active? &&
          self.class.sync_job_pending?(
            connection.id,
            sync_request_token,
            connection.sync_job_id,
            connection.sync_poll_token,
            connection.sync_delivery_job_id
          )
        next result(:active)
      end

      if connection.syncing? && connection.sync_job_id.present?
        next recover_existing_companion_job if recoverable_sync?

        next result(:active)
      end
      next result(:active) if connection.sync_active? && !recoverable_sync?

      queue_new_sync
    end
  end

  def recover_existing_companion_job
    poll_token = SecureRandom.hex(16)
    companion_job_id = connection.sync_job_id
    connection.update!(
      sync_job_id: connection.sync_job_state_value(
        job_id: companion_job_id,
        poll_token: poll_token
      )
    )
    result(
      :resume,
      request_token: sync_request_token,
      expected_sync_job_id: companion_job_id,
      poll_token: poll_token
    )
  end

  def queue_new_sync
    recovering = connection.sync_active?
    poll_token = SecureRandom.hex(16)
    connection.update!(
      sync_status: "queued",
      sync_job_id: connection.sync_job_state_value(job_id: nil, poll_token: poll_token),
      sync_started_at: now,
      last_sync_error: nil
    )
    result(
      recovering ? :recovery : :queued,
      request_token: sync_request_token,
      poll_token: poll_token
    )
  end

  def enqueue(result)
    OwnedLibrarySyncJob.perform_later(
      connection.id,
      result.request_token,
      result.expected_sync_job_id,
      result.poll_token
    )
  rescue StandardError => e
    Rails.logger.error(
      "[AudibleBackup] Failed to enqueue #{mode} sync for connection ##{connection.id}: #{e.class}"
    )
    false
  end

  def mark_enqueue_failed(result)
    connection.with_lock do
      connection.reload
      next unless connection.sync_active?
      next unless sync_request_token == result.request_token
      next unless connection.sync_job_id == result.expected_sync_job_id
      next unless connection.sync_poll_token == result.poll_token

      connection.update!(
        sync_status: "failed",
        sync_job_id: nil,
        sync_started_at: nil,
        last_sync_error: ENQUEUE_FAILURE_MESSAGE
      )
    end
  end

  def persist_enqueued_delivery(result, job)
    delivery_job_id = job.job_id if job.respond_to?(:job_id)
    return if delivery_job_id.blank?

    connection.with_lock do
      connection.reload
      next unless connection.sync_active?
      next unless sync_request_token == result.request_token
      next unless connection.sync_job_id == result.expected_sync_job_id
      next unless connection.sync_poll_token == result.poll_token

      connection.update_column(
        :sync_job_id,
        connection.sync_job_state_value(
          job_id: result.expected_sync_job_id,
          poll_token: result.poll_token,
          delivery_job_id: delivery_job_id
        )
      )
    end
  end

  def advance_scheduled_deadline
    connection.with_lock do
      connection.reload
      next unless connection.scheduled_sync_enabled?

      connection.update!(next_scheduled_sync_at: connection.next_scheduled_sync_time(from: now))
    end
  end

  def recoverable_sync?
    return false unless connection.sync_active?

    connection.updated_at.blank? ||
      connection.updated_at <= OwnedLibrarySyncJob::START_GRACE_PERIOD.ago
  end

  def sync_request_token
    connection.sync_started_at&.utc&.iso8601(6)
  end

  def enqueue_succeeded?(job)
    job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?
  end

  def result(status, **attributes)
    Result.new(status: status, **attributes)
  end

  attr_reader :connection, :mode, :now

  def scheduled?
    mode == :scheduled
  end
end
