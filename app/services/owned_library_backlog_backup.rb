# frozen_string_literal: true

class OwnedLibraryBacklogBackup
  class ConfirmationRequired < ArgumentError; end
  class InvalidRequester < ArgumentError; end
  class ConnectionUnavailable < StandardError; end

  DISPATCH_ENQUEUE_ERROR = "Shelfarr could not queue the next Audible backlog backup"
  CANDIDATE_BATCH_SIZE = 250
  IMPORT_INSERT_BATCH_SIZE = 100
  CANCELLED_MESSAGES = {
    unavailable_item: "This title is no longer an active purchased audiobook",
    already_in_library: "This title is already available in the Shelfarr library",
    local_conflict: "A possible local-library match requires manual review",
    prior_import: "Another backup or import already exists for this title",
    invalid_requester: "The administrator who requested this backlog backup is no longer active"
  }.freeze

  Preview = Data.define(:eligible_count)
  Result = Data.define(
    :status,
    :eligible_count,
    :queued_count,
    :dispatch_job
  ) do
    def queued?
      queued_count.positive?
    end
  end
  DispatchResult = Data.define(:status, :media_import, :job)

  class << self
    def preview(connection:)
      new(connection: connection).preview
    end

    def potential_candidates?(connection:)
      new(connection: connection).potential_candidates?
    end

    def call(connection:, requested_by:, confirmed:)
      new(connection: connection, requested_by: requested_by).call(confirmed: confirmed)
    end

    def dispatch_next(connection:)
      new(connection: connection).dispatch_next
    end

    def pending_connection_ids
      OwnedMediaImport.pending
        .automatic
        .joins(:owned_library_item)
        .distinct
        .pluck("owned_library_items.owned_library_connection_id")
    end
  end

  def initialize(connection:, requested_by: nil)
    @connection = connection
    @requested_by = requested_by
  end

  def preview
    eligible_count = 0
    each_eligible_item { eligible_count += 1 }
    Preview.new(eligible_count: eligible_count)
  end

  # This deliberately answers only whether an inexpensive SQL-prefiltered
  # candidate exists. Exact eligibility requires local edition matching and is
  # calculated after the administrator confirms the one-time action.
  def potential_candidates?
    connection&.persisted? && candidate_scope.exists?
  end

  def call(confirmed:)
    raise ConfirmationRequired, "Backlog backup must be explicitly confirmed" unless confirmed == true

    validate_requester!
    raise ConnectionUnavailable, "Audible Backup must be enabled" unless connection&.persisted? && connection.enabled?
    raise ConnectionUnavailable, "Sync the Audible library before backing up its backlog" if connection.last_synced_at.blank?

    queued_count = 0
    eligible_count = 0
    connection.with_lock do
      connection.reload
      raise ConnectionUnavailable, "Audible Backup must be enabled" unless connection.enabled?
      if connection.last_synced_at.blank?
        raise ConnectionUnavailable, "Sync the Audible library before backing up its backlog"
      end

      now = Time.current
      rows = []
      each_eligible_item do |item|
        eligible_count += 1
        rows << {
          owned_library_item_id: item.id,
          requested_by_id: requested_by.id,
          status: "pending",
          automatic: true,
          separate_edition: false,
          created_at: now,
          updated_at: now
        }
        next unless rows.size >= IMPORT_INSERT_BATCH_SIZE

        queued_count += insert_import_rows(rows)
        rows = []
      end
      queued_count += insert_import_rows(rows)
      connection.update!(backlog_backup_decided_at: now)
    end

    connection.broadcast_owned_library_refresh_later if queued_count.positive?
    dispatch_job = enqueue_dispatcher if queued_count.positive?
    Result.new(
      status: queued_count.positive? ? :queued : :nothing_to_queue,
      eligible_count: eligible_count,
      queued_count: queued_count,
      dispatch_job: dispatch_job
    )
  end

  def dispatch_next
    claim = claim_next_dispatch
    return claim if claim.is_a?(DispatchResult)

    media_import, poll_token = claim
    job = enqueue_backup(media_import, poll_token)
    unless enqueue_succeeded?(job)
      release_dispatch_claim(media_import, poll_token)
      return DispatchResult.new(status: :enqueue_failed, media_import: media_import, job: nil)
    end

    DispatchResult.new(status: :dispatched, media_import: media_import, job: job)
  end

  private

  attr_reader :connection, :requested_by

  def each_eligible_item
    return enum_for(__method__) unless block_given?
    return unless connection&.persisted?

    candidates = candidate_scope
    return unless candidates.exists?

    matcher = OwnedLibraryBookMatcher.new
    candidates.in_batches(of: CANDIDATE_BATCH_SIZE) do |batch|
      candidate_ids = batch.pluck(:id)
      OwnedLibraryItem.where(id: candidate_ids)
        .includes(:book, :owned_media_imports)
        .order(:id)
        .each do |item|
          yield item if eligible_item?(item, matcher: matcher, ignore_import_id: nil)
        end
    end
  end

  def candidate_scope
    connection.owned_library_items
      .active
      .purchased
      .where(media_type: "audiobook")
      .left_outer_joins(:book, :owned_media_imports)
      .where(owned_media_imports: { id: nil })
      .where("books.id IS NULL OR books.file_path IS NULL OR TRIM(books.file_path) = ''")
  end

  def insert_import_rows(rows)
    return 0 if rows.empty?

    OwnedMediaImport.insert_all!(rows)
    rows.size
  end

  def eligible_item?(item, matcher:, ignore_import_id:)
    return false unless item.active? && item.purchased? && item.media_type == "audiobook"
    return false if item.book&.acquisition_blocked?
    return false if prior_import_exists?(item, ignore_import_id: ignore_import_id)

    resolution = matcher.resolve(item)
    !resolution.matched? && !resolution.conflict?
  end

  def validate_requester!
    return if requested_by&.persisted? && requested_by.admin? && requested_by.deleted_at.blank?

    raise InvalidRequester, "Backlog backup requires an active administrator"
  end

  def claim_next_dispatch
    connection.with_lock do
      connection.reload
      next dispatch_result(:disabled) unless connection.enabled?
      next dispatch_result(:auth_active) if connection.auth_active?
      next dispatch_result(:sync_active) if connection.sync_active?
      next dispatch_result(:sync_due) if connection.scheduled_sync_due?
      next dispatch_result(:backup_active) if connection.owned_media_imports.active.exists?

      matcher = OwnedLibraryBookMatcher.new
      loop do
        media_import = next_pending_import
        break dispatch_result(:empty) unless media_import

        reason = dispatch_ineligibility(media_import, matcher)
        if reason
          cancel_pending_import(media_import, reason)
          next
        end

        poll_token = OwnedMediaImport.generate_poll_token
        media_import.update!(
          status: "queued",
          poll_token: poll_token,
          dispatched_at: Time.current,
          error_message: nil
        )
        break [ media_import, poll_token ]
      end
    end
  end

  def next_pending_import
    connection.owned_media_imports
      .pending
      .automatic
      .includes(owned_library_item: [ :book, :owned_media_imports ])
      .order(:created_at, :id)
      .first
  end

  def dispatch_ineligibility(media_import, matcher)
    item = media_import.owned_library_item
    return :invalid_requester unless active_admin?(media_import.requested_by)
    return :unavailable_item unless item.active? && item.purchased? && item.media_type == "audiobook"
    return :already_in_library if item.book&.acquisition_blocked?

    resolution = matcher.resolve(item)
    return :already_in_library if resolution.matched?
    return :local_conflict if resolution.conflict?
    return :prior_import if item.owned_media_imports.where.not(id: media_import.id).exists?

    nil
  end

  def active_admin?(user)
    user&.admin? && user.deleted_at.blank?
  end

  def prior_import_exists?(item, ignore_import_id:)
    imports = item.owned_media_imports
    if imports.loaded?
      imports.any? { |media_import| media_import.id != ignore_import_id }
    else
      imports = imports.where.not(id: ignore_import_id) if ignore_import_id
      imports.exists?
    end
  end

  def cancel_pending_import(media_import, reason)
    media_import.update!(
      status: "cancelled",
      error_message: CANCELLED_MESSAGES.fetch(reason),
      completed_at: Time.current
    )
  end

  def enqueue_dispatcher
    OwnedLibraryAutomationJob.perform_later
  rescue StandardError => error
    Rails.logger.error(
      "[AudibleBackup] Could not immediately dispatch the confirmed backlog: #{error.class}"
    )
    nil
  end

  def enqueue_backup(media_import, poll_token)
    OwnedMediaBackupJob.perform_later(media_import.id, poll_token)
  rescue StandardError => error
    Rails.logger.error(
      "[AudibleBackup] Could not enqueue backlog import ##{media_import.id}: #{error.class}"
    )
    nil
  end

  def enqueue_succeeded?(job)
    job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?
  end

  def release_dispatch_claim(media_import, poll_token)
    media_import.with_lock do
      media_import.reload
      next unless media_import.queued? && media_import.external_job_id.blank?
      next unless media_import.poll_token_matches?(poll_token)

      media_import.update!(
        status: "pending",
        poll_token: nil,
        dispatched_at: nil,
        error_message: DISPATCH_ENQUEUE_ERROR
      )
    end
  end

  def dispatch_result(status)
    DispatchResult.new(status: status, media_import: nil, job: nil)
  end
end
