# frozen_string_literal: true

class OwnedLibrarySyncJob < ApplicationJob
  class CompanionJobFailed < StandardError; end

  SyncAttempt = Struct.new(:request_token, :job_id, :poll_token, keyword_init: true)

  POLL_INTERVAL = 15.seconds
  START_GRACE_PERIOD = 1.minute
  DEFAULT_SYNC_TIMEOUT_MINUTES = 120
  JOB_CONCURRENCY_LEASE = 10.minutes
  SAFE_PROVIDER_METADATA_KEYS = %w[
    bookStatus contentType datePublished hasPdf includedUntil lastDownloaded
    pdfStatus series
  ].freeze
  RECONCILIATION_BATCH_SIZE = 250
  OWNED_LIBRARY_ITEM_UNIQUE_INDEX =
    "index_owned_library_items_on_connection_and_external_id".freeze

  queue_as :default
  limits_concurrency to: 1,
    key: ->(connection_id, *) { "owned-library-sync-#{connection_id}" },
    duration: JOB_CONCURRENCY_LEASE

  def perform(connection_id, request_token = nil, expected_sync_job_id = nil, poll_token = nil)
    database_logger = ActiveRecord::Base.logger
    if database_logger&.respond_to?(:silence)
      database_logger.silence(Logger::INFO) do
        perform_with_database_privacy(
          connection_id,
          request_token,
          expected_sync_job_id,
          poll_token
        )
      end
    else
      perform_with_database_privacy(
        connection_id,
        request_token,
        expected_sync_job_id,
        poll_token
      )
    end
  end

  private

  # Reconciliation writes personal Audible catalog metadata through bulk SQL.
  # Active Record's DEBUG output includes those values, so mute DEBUG binds for
  # this job while retaining identifier-only INFO, warning, and error messages.
  def perform_with_database_privacy(
    connection_id,
    request_token,
    expected_sync_job_id,
    poll_token
  )
    attempt = SyncAttempt.new(
      request_token: request_token,
      job_id: expected_sync_job_id,
      poll_token: poll_token
    )
    connection = OwnedLibraryConnection.find_by(id: connection_id)
    return unless connection

    unless connection.enabled?
      reset_disabled_connection(connection)
      return
    end
    return if connection.auth_active?

    normalize_legacy_attempt(connection, attempt)
    return unless prepare_poll_attempt(connection, attempt)

    if attempt.job_id.present?
      return unless terminal_request_current?(connection, attempt)

      poll_sync(connection, attempt)
    elsif connection.queued?
      return unless current_request?(connection, attempt.request_token)

      start_sync(connection, attempt) if claim_sync(connection, attempt)
    elsif connection.syncing? && current_request?(connection, attempt.request_token)
      resume_sync(connection, attempt)
    end
  rescue LibationCompanionClient::Error, CompanionJobFailed => e
    fail_sync(connection, e.message, attempt) if connection
    raise
  rescue StandardError => e
    if connection
      fail_sync(
        connection,
        "Unexpected #{e.class} while syncing the Audible library",
        attempt
      )
    end
    raise
  end

  def resume_sync(connection, attempt)
    return if connection.sync_started_at.present? && connection.sync_started_at > START_GRACE_PERIOD.ago

    if claim_sync(connection, attempt)
      # The companion de-duplicates active sync jobs, so this safely recovers
      # a crash after the job was accepted but before its ID reached SQLite.
      start_sync(connection, attempt)
    end
  end

  def claim_sync(connection, attempt)
    connection.with_lock do
      connection.reload
      next false unless poll_attempt_current?(connection, attempt)
      next false if connection.syncing? && connection.sync_job_id.present?
      next false if connection.syncing? && connection.sync_started_at.present? &&
        connection.sync_started_at > START_GRACE_PERIOD.ago

      next_poll_token = SecureRandom.hex(16)
      connection.update!(
        sync_status: "syncing",
        sync_job_id: connection.sync_job_state_value(
          job_id: nil,
          poll_token: next_poll_token,
          delivery_job_id: job_id
        ),
        sync_started_at: connection.sync_started_at || Time.current,
        last_sync_error: nil
      )
      attempt.poll_token = next_poll_token
      true
    end
  end

  def start_sync(connection, attempt)
    companion_job = connection.client.start_sync
    attached = connection.with_lock do
      connection.reload
      next false unless terminal_request_current?(connection, attempt)
      next false if connection.sync_job_id.present?

      next_poll_token = SecureRandom.hex(16)
      connection.update!(
        sync_job_id: connection.sync_job_state_value(
          job_id: companion_job.id,
          poll_token: next_poll_token,
          delivery_job_id: job_id
        )
      )
      attempt.job_id = companion_job.id
      attempt.poll_token = next_poll_token
      true
    end
    return unless attached

    handle_companion_job(connection, companion_job, attempt)
  end

  def poll_sync(connection, attempt)
    if sync_expired?(connection)
      raise CompanionJobFailed, "Libation library sync timed out"
    end

    companion_job = connection.client.job(attempt.job_id)
    handle_companion_job(connection, companion_job, attempt)
  end

  def handle_companion_job(connection, companion_job, attempt)
    if companion_job.completed?
      reconcile_library(connection, attempt)
    elsif companion_job.failed? || companion_job.cancelled?
      raise CompanionJobFailed, companion_job.error.presence || "Libation library sync #{companion_job.status}"
    elsif advance_poll_chain(connection, attempt)
      schedule_poll(connection, attempt)
    end
  end

  def reconcile_library(connection, attempt)
    client = connection.client
    entries = deduplicate_entries(client.library)
    now = Time.current
    local_book_matcher = OwnedLibraryBookMatcher.new
    automatic_import_count = 0

    applied = connection.transaction do
      connection.lock!
      next false unless terminal_request_current?(connection, attempt)

      automatic_backups_enabled = automatic_backups_enabled_for_reconciliation?(connection)
      items_by_external_id = connection.owned_library_items
        .select(
          :id,
          :owned_library_connection_id,
          :book_id,
          :external_id,
          :ownership_type,
          :downloaded,
          :backed_up_at,
          :file_path,
          :created_at
        )
        .index_by(&:external_id)
      acquired_book_ids = acquired_book_ids(items_by_external_id.values)

      connection.owned_library_items.update_all(
        active: false,
        absent_since: now,
        updated_at: now
      )

      rows, automatic_candidate_external_ids = build_reconciliation_rows(
        connection,
        entries,
        items_by_external_id,
        local_book_matcher,
        acquired_book_ids,
        automatic_backups_enabled: automatic_backups_enabled,
        now: now
      )
      upsert_reconciliation_rows(rows)
      automatic_import_count = create_automatic_imports(
        connection,
        automatic_candidate_external_ids,
        now: now
      )

      connection.update!(successful_sync_attributes(connection, now))
      true
    end

    if applied
      dispatch_automatic_backup(connection) if automatic_import_count.positive?
      update_versions(connection, client)
    end
  end

  def deduplicate_entries(entries)
    entries.each_with_object({}) do |entry, entries_by_external_id|
      entries_by_external_id[entry.external_id] = entry
    end.values
  end

  def acquired_book_ids(items)
    book_ids = items.filter_map(&:book_id).uniq
    return {} if book_ids.empty?

    book_ids.each_slice(RECONCILIATION_BATCH_SIZE).flat_map do |batch|
      Book.acquired.where(id: batch).pluck(:id)
    end.index_with(true)
  end

  def build_reconciliation_rows(
    connection,
    entries,
    items_by_external_id,
    local_book_matcher,
    acquired_book_ids,
    automatic_backups_enabled:,
    now:
  )
    automatic_candidate_external_ids = []
    rows = entries.map do |entry|
      item = items_by_external_id[entry.external_id] ||
        OwnedLibraryItem.new(
          owned_library_connection_id: connection.id,
          external_id: entry.external_id
        )
      newly_discovered = item.new_record?
      became_purchased = !newly_discovered && !item.purchased? &&
        entry.ownership_type == "purchased"
      item.assign_attributes(
        title: entry.title,
        subtitle: entry.subtitle,
        authors: entry.authors,
        narrators: entry.narrators
      )
      local_resolution = local_book_matcher.resolve(item)
      book_id = reconciliation_book_id(item, entry, local_resolution)
      locally_backed_up = !!(item.downloaded? || item.backed_up_at.present?)
      backed_up_at = item.backed_up_at
      backed_up_at ||= now if entry.downloaded || locally_backed_up
      attributes = reconciliation_attributes(
        connection,
        item,
        entry,
        book_id: book_id,
        backed_up_at: backed_up_at,
        locally_backed_up: locally_backed_up,
        now: now
      )
      validate_reconciliation_attributes!(item, attributes)

      if automatic_backups_enabled && automatic_backup_candidate?(
        entry,
        local_resolution,
        book_id: book_id,
        acquired_book_ids: acquired_book_ids,
        newly_discovered: newly_discovered,
        became_purchased: became_purchased
      )
        automatic_candidate_external_ids << entry.external_id
      end

      attributes
    end

    [ rows, automatic_candidate_external_ids ]
  end

  def reconciliation_book_id(item, entry, local_resolution)
    return item.book_id if item.book_id.present?
    return unless local_resolution.matched?
    return unless entry.ownership_type == "purchased" && entry.active
    return unless entry.media_type == "audiobook"

    local_resolution.book.id
  end

  def reconciliation_attributes(
    connection,
    item,
    entry,
    book_id:,
    backed_up_at:,
    locally_backed_up:,
    now:
  )
    {
      owned_library_connection_id: connection.id,
      external_id: entry.external_id,
      book_id: book_id,
      media_type: entry.media_type,
      title: entry.title,
      subtitle: entry.subtitle,
      authors: entry.authors,
      narrators: entry.narrators,
      cover_url: entry.cover_url,
      language: entry.language,
      duration_seconds: entry.duration_seconds,
      ownership_type: entry.ownership_type,
      purchased_at: entry.purchased_at,
      active: entry.active,
      downloaded: entry.downloaded || locally_backed_up,
      backed_up_at: backed_up_at,
      file_path: entry.file_path.presence || item.file_path,
      last_seen_at: now,
      absent_since: entry.active ? nil : now,
      provider_metadata: entry.payload.slice(*SAFE_PROVIDER_METADATA_KEYS),
      created_at: item.created_at || now,
      updated_at: now
    }
  end

  def validate_reconciliation_attributes!(item, attributes)
    item.assign_attributes(
      attributes.except(
        :owned_library_connection_id,
        :created_at,
        :updated_at
      )
    )
    item.errors.clear

    # Bulk upserts intentionally skip the per-row uniqueness query. The
    # connection/external-ID database index remains the authoritative guard;
    # every other model validator still runs against the in-memory row.
    item.class.validators.each do |validator|
      next if validator.is_a?(ActiveRecord::Validations::UniquenessValidator)

      validator.validate(item)
    end
    raise ActiveRecord::RecordInvalid.new(item) if item.errors.any?
  end

  def upsert_reconciliation_rows(rows)
    rows.each_slice(RECONCILIATION_BATCH_SIZE) do |batch|
      OwnedLibraryItem.upsert_all(
        batch,
        unique_by: OWNED_LIBRARY_ITEM_UNIQUE_INDEX,
        record_timestamps: false
      )
    end
  end

  def automatic_backups_enabled_for_reconciliation?(connection)
    # The first successful scan after automatic backup is enabled refreshes the
    # ownership baseline. This matters when the previous cached snapshot is
    # stale: purchases made before opt-in must not be mistaken for future ones.
    return false unless connection.automatic_backup_baseline_ready?

    user = connection.automatic_backup_user
    user.admin?
  end

  def automatic_backup_candidate?(
    entry,
    local_resolution,
    book_id:,
    acquired_book_ids:,
    newly_discovered:,
    became_purchased:
  )
    return false unless newly_discovered || became_purchased
    return false unless entry.ownership_type == "purchased" && entry.active
    return false unless entry.media_type == "audiobook"
    return false if acquired_book_ids.key?(book_id)
    return false if local_resolution.matched? || local_resolution.conflict?

    true
  end

  def create_automatic_imports(connection, external_ids, now:)
    return 0 if external_ids.empty?

    item_ids = external_ids.each_slice(RECONCILIATION_BATCH_SIZE).flat_map do |batch|
      connection.owned_library_items.where(external_id: batch).pluck(:id)
    end
    blocked_item_ids = automatic_backup_blocked_item_ids(item_ids)
    item_ids -= blocked_item_ids
    return 0 if item_ids.empty?

    rows = item_ids.map do |item_id|
      {
        owned_library_item_id: item_id,
        requested_by_id: connection.automatic_backup_user_id,
        status: "pending",
        automatic: true,
        separate_edition: false,
        created_at: now,
        updated_at: now
      }
    end
    rows.each_slice(RECONCILIATION_BATCH_SIZE) do |batch|
      OwnedMediaImport.insert_all!(batch)
    end
    rows.size
  end

  def automatic_backup_blocked_item_ids(item_ids)
    return [] if item_ids.empty?

    nonterminal_statuses = [ "pending", *OwnedMediaImport::ACTIVE_STATUSES ]
    item_ids.each_slice(RECONCILIATION_BATCH_SIZE).flat_map do |batch|
      OwnedMediaImport
        .where(owned_library_item_id: batch)
        .where(
          "status IN (:nonterminal) OR " \
            "(automatic = :automatic AND status IN (:terminal))",
          nonterminal: nonterminal_statuses,
          automatic: true,
          terminal: OwnedMediaImport::TERMINAL_STATUSES
        )
        .distinct
        .pluck(:owned_library_item_id)
    end
  end

  def dispatch_automatic_backup(connection)
    OwnedLibraryBacklogBackup.dispatch_next(connection: connection)
  rescue StandardError => error
    # Pending rows are durable; the recurring automation watchdog will retry
    # admission if the immediate handoff cannot run after the sync commits.
    Rails.logger.error(
      "[OwnedLibrarySyncJob] Could not dispatch the next automatic backup: #{error.class}"
    )
  end

  def successful_sync_attributes(connection, now)
    attributes = {
      sync_status: "idle",
      sync_job_id: nil,
      sync_started_at: nil,
      last_synced_at: now,
      last_sync_error: nil
    }
    if connection.has_attribute?(:next_scheduled_sync_at)
      attributes[:next_scheduled_sync_at] = next_scheduled_sync_time(connection, now)
    end
    attributes
  end

  def next_scheduled_sync_time(connection, now)
    return unless connection.scheduled_sync_enabled?
    return connection.next_scheduled_sync_at unless connection.respond_to?(:next_scheduled_sync_time)

    connection.next_scheduled_sync_time(from: now)
  end

  def update_versions(connection, client)
    version = client.version
    connection.update!(
      companion_version: version.companion_version,
      provider_version: version.libation_version
    )
  rescue LibationCompanionClient::Error => e
    Rails.logger.warn "[OwnedLibrarySyncJob] Library synced but version lookup failed: #{e.message}"
  end

  def schedule_poll(connection, attempt)
    scheduled_job = self.class.set(wait: POLL_INTERVAL).perform_later(
      connection.id,
      attempt.request_token,
      attempt.job_id,
      attempt.poll_token
    )
    if scheduled_job.respond_to?(:successfully_enqueued?) && scheduled_job.successfully_enqueued?
      persist_scheduled_delivery(connection, attempt, scheduled_job)
      return
    end

    raise CompanionJobFailed, "Shelfarr could not queue the next Libation sync check"
  end

  def sync_expired?(connection)
    connection.sync_started_at.blank? || connection.sync_started_at <= max_sync_runtime.ago
  end

  def current_request?(connection, request_token)
    request_token.present? && sync_request_token(connection) == request_token
  end

  def normalize_legacy_attempt(connection, attempt)
    if attempt.job_id.blank? && connection.syncing? &&
        attempt.request_token.present? && attempt.request_token == connection.sync_job_id
      attempt.request_token = sync_request_token(connection)
      attempt.job_id = connection.sync_job_id
    elsif attempt.request_token.blank? && connection.queued?
      attempt.request_token = sync_request_token(connection)
    end
  end

  def sync_request_token(connection)
    connection.sync_started_at&.utc&.iso8601(6)
  end

  def prepare_poll_attempt(connection, attempt)
    return false unless current_request?(connection, attempt.request_token)

    if attempt.poll_token.present?
      claim_delivery_liveness(connection, attempt)
    else
      claim_legacy_poll_chain(connection, attempt)
    end
  end

  def claim_legacy_poll_chain(connection, attempt)
    connection.with_lock do
      connection.reload
      next false unless current_request?(connection, attempt.request_token)
      next false unless connection.sync_job_id == attempt.job_id
      next false if connection.sync_poll_token.present?

      attempt.poll_token = SecureRandom.hex(16)
      write_poll_state(
        connection,
        attempt.job_id,
        attempt.poll_token,
        delivery_job_id: job_id
      )
      true
    end
  end

  def claim_delivery_liveness(connection, attempt)
    connection.with_lock do
      connection.reload
      next false unless poll_attempt_current?(connection, attempt)

      write_poll_state(
        connection,
        attempt.job_id,
        attempt.poll_token,
        delivery_job_id: job_id
      )
      true
    end
  end

  def poll_attempt_current?(connection, attempt)
    current_request?(connection, attempt.request_token) &&
      connection.sync_job_id == attempt.job_id &&
      connection.sync_poll_token == attempt.poll_token
  end

  def terminal_request_current?(connection, attempt)
    connection.syncing? && poll_attempt_current?(connection, attempt)
  end

  def advance_poll_chain(connection, attempt)
    connection.with_lock do
      connection.reload
      next false unless terminal_request_current?(connection, attempt)

      attempt.poll_token = SecureRandom.hex(16)
      write_poll_state(
        connection,
        attempt.job_id,
        attempt.poll_token,
        delivery_job_id: job_id
      )
      true
    end
  end

  def write_poll_state(connection, companion_job_id, poll_token, delivery_job_id:)
    heartbeat_at = [ Time.current, connection.updated_at + 0.000001 ].max
    connection.update_columns(
      sync_job_id: connection.sync_job_state_value(
        job_id: companion_job_id,
        poll_token: poll_token,
        delivery_job_id: delivery_job_id
      ),
      updated_at: heartbeat_at
    )
  end

  def persist_scheduled_delivery(connection, attempt, scheduled_job)
    delivery_job_id = scheduled_job.job_id if scheduled_job.respond_to?(:job_id)
    return if delivery_job_id.blank?

    connection.with_lock do
      connection.reload
      next unless terminal_request_current?(connection, attempt)

      write_poll_state(
        connection,
        attempt.job_id,
        attempt.poll_token,
        delivery_job_id: delivery_job_id
      )
    end
  end

  def max_sync_runtime
    minutes = Integer(
      ENV.fetch("SHELFARR_LIBATION_SYNC_TIMEOUT_MINUTES", DEFAULT_SYNC_TIMEOUT_MINUTES),
      exception: false
    )
    minutes = DEFAULT_SYNC_TIMEOUT_MINUTES unless minutes&.positive?
    minutes.minutes
  end

  def fail_sync(connection, message, attempt)
    # Reconciliation runs in a transaction. When it rolls back, Active Record can
    # retain rolled-back attributes on this instance. Lock and reload before the
    # terminal write so an old poll cannot overwrite a completed or newer sync.
    connection.reload if connection.has_changes_to_save?
    connection.with_lock do
      connection.reload
      next false unless terminal_request_current?(connection, attempt)

      now = Time.current
      attributes = {
        sync_status: "failed",
        sync_job_id: nil,
        sync_started_at: nil,
        last_sync_error: message.to_s.truncate(2_000)
      }
      if connection.has_attribute?(:next_scheduled_sync_at)
        attributes[:next_scheduled_sync_at] = next_scheduled_sync_time(connection, now)
      end
      connection.update!(attributes)
      true
    end
  end

  def reset_disabled_connection(connection)
    return unless connection.sync_active?

    connection.update!(sync_status: "idle", sync_job_id: nil, sync_started_at: nil)
  end
end
