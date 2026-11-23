# frozen_string_literal: true

class OwnedLibraryConnectionWorkflow
  ITEMS_PER_PAGE = 50
  AUTOMATION_INTERVAL_OPTIONS = [
    [ "Every hour", 60 ],
    [ "Every 6 hours", 360 ],
    [ "Every 12 hours", 720 ],
    [ "Every 24 hours", 1_440 ],
    [ "Every 3 days", 4_320 ],
    [ "Weekly", 10_080 ]
  ].freeze
  CONNECTION_ATTRIBUTES = %i[url bridge_token enabled allow_private_network timeout_seconds].freeze
  AUTOMATION_ATTRIBUTES = %i[scheduled_sync_enabled scheduled_sync_interval_minutes automatic_backup_enabled].freeze
  BACKUP_ENQUEUE_FAILURE = "Shelfarr could not queue the Libation backup"

  CompletionClaim = Data.define(:pending_state, :auth_state, :endpoint)
  ConnectionTest = Data.define(:status, :companion_version, :libation_version, :health_status, :error)
  SignInStart = Data.define(:status, :login_url, :error)
  SignInCompletion = Data.define(:status, :error)
  AutomationChange = Data.define(:status, :scheduled_sync_enabled, :automatic_backup_enabled)
  ItemBackup = Data.define(:status, :item)
  ExistingBackup = Data.define(:status, :queued_count, :error)

  class Summary
    attr_reader :connection, :accounts, :companion_error, :library_total_items, :purchased_items,
      :subscription_items, :active_backup_counts, :active_backup_total, :backlog_backup_available,
      :backlog_backup_prompt, :backlog_backup_counts, :backlog_backup_total, :backlog_backup_remaining,
      :backlog_backup_processed, :sync_recoverable, :sync_state

    def initialize(workflow, auth_pending:, quiet_during_backlog:)
      @workflow = workflow
      @quiet_during_backlog = quiet_during_backlog
      @connection = workflow.connection
      load_library_summary
      @accounts = []
      @audible_connected = @library_total_items.positive? || connection.last_synced_at.present? || connection.sync_active?
      workflow.clear_stale_auth_state
      @auth_starting = connection.persisted? && connection.auth_starting?
      @auth_pending = auth_pending || (connection.persisted? && connection.auth_pending?)
      load_accounts
    end

    def audible_connected? = @audible_connected
    def companion_available? = @companion_available == true
    def companion_busy? = @companion_busy == true
    def auth_starting? = @auth_starting
    def auth_pending? = @auth_pending
    def auth_active? = @auth_starting || @auth_pending
    def login_url = (connection.auth_login_url if @auth_pending)

    private

    def load_accounts
      return unless connection.persisted? && connection.enabled?
      return @companion_busy = true if auth_active? || @workflow.active_operation?
      return @companion_busy = true if @quiet_during_backlog && @backlog_backup_remaining.positive?

      @accounts = connection.client.accounts
      @audible_connected = @accounts.any?(&:authenticated)
      @companion_available = true
    rescue LibationCompanionClient::BusyError
      @companion_busy = true
    rescue LibationCompanionClient::Error => e
      @companion_error = e.message
    end

    def load_library_summary
      scope = connection.persisted? ? connection.owned_library_items.active : OwnedLibraryItem.none
      @library_total_items = scope.count
      ownership_counts = scope.group(:ownership_type).count
      @purchased_items = ownership_counts.fetch("purchased", 0)
      @subscription_items = ownership_counts.fetch("subscription", 0)
      @active_backup_counts = connection.persisted? ? connection.owned_media_imports.active.group(:status).count : {}
      @active_backup_total = @active_backup_counts.values.sum
      load_backlog_backup_summary
      @sync_recoverable = connection.persisted? && recoverable_sync?
      @sync_state = if connection.queued?
        "queued"
      elsif connection.syncing?
        "syncing"
      elsif connection.failed?
        "failed"
      elsif connection.last_synced_at.present?
        "succeeded"
      else
        "never_synced"
      end
    end

    def load_backlog_backup_summary
      @backlog_backup_available = false
      @backlog_backup_prompt = false
      @backlog_backup_counts = {}
      @backlog_backup_total = 0
      @backlog_backup_remaining = 0
      @backlog_backup_processed = 0
      return unless connection.persisted? && connection.last_synced_at.present?

      @backlog_backup_available = OwnedLibraryBacklogBackup.potential_candidates?(connection: connection)
      @backlog_backup_prompt = !connection.backlog_backup_decided? && @backlog_backup_available

      backlog_scope = connection.owned_media_imports.where(status: "pending").or(
        connection.owned_media_imports.where.not(dispatched_at: nil)
      )
      @backlog_backup_counts = backlog_scope.group(:status).count
      @backlog_backup_total = @backlog_backup_counts.values.sum
      @backlog_backup_remaining = @backlog_backup_counts.values_at("pending", *OwnedMediaImport::ACTIVE_STATUSES).compact.sum
      @backlog_backup_processed = @backlog_backup_counts.values_at(*OwnedMediaImport::TERMINAL_STATUSES).compact.sum
    end

    def recoverable_sync?
      return false unless connection.sync_active?

      connection.updated_at.blank? || connection.updated_at <= OwnedLibrarySyncJob::START_GRACE_PERIOD.ago
    end
  end

  Catalogue = Data.define(:query, :page, :total_pages, :total_items, :items)

  def self.default_connection
    OwnedLibraryConnection.for_provider("libation").first_or_initialize do |connection|
      connection.name = "Audible Backup"
      connection.url = OwnedLibraryConnection.default_libation_url
      connection.allow_private_network = true
      connection.enabled = false
    end
  end

  attr_reader :connection

  def initialize(connection, user:)
    @connection = connection
    @user = user
  end

  def summary(auth_pending: false, quiet_during_backlog: false)
    Summary.new(self, auth_pending: auth_pending, quiet_during_backlog: quiet_during_backlog)
  end

  def catalogue(query:, page:)
    query = query.to_s.strip.first(200)
    page = [ page.to_i, 1 ].max
    scope = connection.persisted? ? connection.owned_library_items.includes(:book).active.alphabetical : OwnedLibraryItem.none
    if query.present?
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query.downcase)}%"
      scope = scope.where(
        "LOWER(owned_library_items.title) LIKE :pattern OR " \
          "LOWER(CAST(owned_library_items.authors AS TEXT)) LIKE :pattern",
        pattern: pattern
      )
    end

    total_items = scope.count
    total_pages = [ (total_items.to_f / ITEMS_PER_PAGE).ceil, 1 ].max
    page = total_pages if page > total_pages
    items = scope.offset((page - 1) * ITEMS_PER_PAGE).limit(ITEMS_PER_PAGE).to_a
    OwnedLibraryItem.preload_latest_imports(items)
    Catalogue.new(query: query, page: page, total_pages: total_pages, total_items: total_items, items: items)
  end

  def active_operation?
    connection.auth_active? || connection.sync_active? || connection.owned_media_imports.active.exists?
  end

  def save_connection(attributes)
    attributes = attributes.to_h.symbolize_keys.slice(*CONNECTION_ATTRIBUTES)
    return create_connection(attributes) unless connection.persisted?

    attributes = attributes.except(:bridge_token) if attributes[:bridge_token].blank?
    requested_enabled = ActiveModel::Type::Boolean.new.cast(attributes.fetch(:enabled, connection.enabled?))
    return :storage_not_ready if requested_enabled && !audiobook_storage_ready?

    connection.with_lock do
      connection.reload
      identity_changed = endpoint_identity_change?(attributes)
      if active_operation?
        :busy
      elsif identity_changed && account_bound_backup_state?
        :pending_backups
      elsif connection.update(attributes)
        reset_account_bound_catalog! if identity_changed
        :saved
      else
        :invalid
      end
    end
  end

  def test_connection
    return ConnectionTest.new(status: :busy, companion_version: nil, libation_version: nil, health_status: nil, error: nil) if active_operation?

    client = connection.client
    health = client.health
    secrets = client.secret_values
    version = client.version
    secrets |= client.secret_values
    companion_version = reportable(version.companion_version, secrets)
    libation_version = reportable(version.libation_version, secrets)
    connection.update!(companion_version: companion_version, provider_version: libation_version)
    ConnectionTest.new(
      status: :connected,
      companion_version: companion_version,
      libation_version: libation_version,
      health_status: reportable(health.is_a?(Hash) ? health["status"].presence&.to_s : nil, secrets),
      error: nil
    )
  rescue LibationCompanionClient::Error => e
    ConnectionTest.new(status: :failed, companion_version: nil, libation_version: nil, health_status: nil, error: e)
  end

  def start_sign_in(account:, locale:, reregister:)
    auth_request_token = claim_auth_start
    return SignInStart.new(status: :busy, login_url: nil, error: nil) unless auth_request_token

    auth_session = connection.client.start_auth(
      account: account,
      locale: locale,
      reregister: ActiveModel::Type::Boolean.new.cast(reregister)
    )
    if auth_session.authenticated
      clear_auth_start_claim(auth_request_token)
      return SignInStart.new(status: :authenticated, login_url: nil, error: nil)
    end
    return SignInStart.new(status: :expired, login_url: nil, error: nil) unless persist_auth_session(auth_request_token, auth_session)

    SignInStart.new(status: :pending, login_url: auth_session.login_url, error: nil)
  rescue ArgumentError, LibationCompanionClient::Error => e
    clear_auth_start_claim(auth_request_token) if auth_request_token
    SignInStart.new(status: :failed, login_url: nil, error: e)
  end

  def complete_sign_in(response_url:, &proof)
    auth_state = auth_state_for_completion(proof)
    return SignInCompletion.new(status: :expired, error: nil) unless auth_state

    connection.client.complete_auth(session_id: auth_state.fetch(:session_id), response_url: response_url)
    invalidate_account_bound_catalog_after_auth!(auth_state)
    SignInCompletion.new(status: :connected, error: nil)
  rescue ArgumentError, LibationCompanionClient::Error => e
    SignInCompletion.new(status: :failed, error: e)
  end

  def complete_sign_in_once(response_url:, &proof)
    claim = claim_completion(response_url, proof)
    return SignInCompletion.new(status: claim, error: nil) if claim.is_a?(Symbol)

    connection.client.complete_auth(session_id: claim.pending_state.fetch(:session_id), response_url: response_url)
    finish_completion(claim)
  rescue ArgumentError, LibationCompanionClient::ConnectionError => e
    restore_completion(claim) if claim.is_a?(CompletionClaim)
    SignInCompletion.new(status: :failed, error: e)
  rescue LibationCompanionClient::Error => e
    abandon_completion(claim) if claim.is_a?(CompletionClaim)
    SignInCompletion.new(status: :failed, error: e)
  end

  def self.same_marketplace?(login_url, response_url)
    roots = marketplace_roots(URI.parse(login_url.to_s).host)
    host = URI.parse(response_url.to_s.strip).host.to_s.downcase
    roots.any? { |root| host == root || host.end_with?(".#{root}") }
  rescue URI::InvalidURIError
    false
  end

  def self.marketplace_roots(login_host)
    host = login_host.to_s.downcase
    suffix = LibationCompanionClient::AUTH_HOST_SUFFIXES
      .select { |candidate| host == candidate || host.end_with?(".#{candidate}") }
      .max_by(&:length)
    return [] unless suffix

    domain = suffix.sub(/\A(?:amazon|audible)\./, "")
    [ "amazon.#{domain}", "audible.#{domain}" ]
  end

  def sync
    OwnedLibrarySyncRequest.call(connection: connection, mode: :manual)
  end

  def back_up_existing(confirmed:)
    OwnedMediaImportFileService.verify_filesystem_capabilities!
    result = OwnedLibraryBacklogBackup.call(connection: connection, requested_by: @user, confirmed: confirmed)
    ExistingBackup.new(status: result.queued? ? :queued : :none_eligible, queued_count: result.queued_count, error: nil)
  rescue OwnedLibraryBacklogBackup::ConfirmationRequired => e
    ExistingBackup.new(status: :confirmation_required, queued_count: 0, error: e)
  rescue OwnedLibraryBacklogBackup::InvalidRequester, OwnedLibraryBacklogBackup::ConnectionUnavailable => e
    ExistingBackup.new(status: :refused, queued_count: 0, error: e)
  rescue OwnedMediaImportFileService::Error => e
    ExistingBackup.new(status: :storage_not_ready, queued_count: 0, error: e)
  rescue ActiveRecord::RecordNotUnique
    ExistingBackup.new(status: :changed, queued_count: 0, error: nil)
  end

  def dismiss_existing_backup
    connection.update!(backlog_backup_decided_at: Time.current)
  end

  def update_automation(attributes)
    attributes = attributes.to_h.symbolize_keys.slice(*AUTOMATION_ATTRIBUTES)
    scheduled_sync_enabled = ActiveModel::Type::Boolean.new.cast(attributes[:scheduled_sync_enabled])
    automatic_backup_enabled = ActiveModel::Type::Boolean.new.cast(attributes[:automatic_backup_enabled])
    if automatic_backup_enabled && !audiobook_storage_ready?
      return AutomationChange.new(status: :storage_not_ready, scheduled_sync_enabled: scheduled_sync_enabled, automatic_backup_enabled: automatic_backup_enabled)
    end

    status = connection.with_lock do
      connection.reload
      next :disabled unless connection.enabled?
      next :schedule_required if automatic_backup_enabled && !scheduled_sync_enabled && !connection.scheduled_sync_enabled?

      automatic_backup_enabled = false unless scheduled_sync_enabled
      attributes[:scheduled_sync_enabled] = scheduled_sync_enabled
      attributes[:automatic_backup_enabled] = automatic_backup_enabled
      next :baseline_required if automatic_backup_enabled && connection.last_synced_at.blank?
      next :sync_active if automatic_backup_enabled && !connection.automatic_backup_enabled? && connection.sync_active?

      if automatic_backup_enabled
        attributes[:automatic_backup_user] = @user unless connection.automatic_backup_ready?
        attributes[:automatic_backup_enabled_at] = connection.automatic_backup_enabled_at.presence || Time.current
      else
        attributes[:automatic_backup_user] = nil
        attributes[:automatic_backup_enabled_at] = nil
      end

      connection.update(attributes) ? :saved : :invalid
    end
    AutomationChange.new(status: status, scheduled_sync_enabled: scheduled_sync_enabled, automatic_backup_enabled: automatic_backup_enabled)
  end

  def back_up_item(item_id:, separate_edition:, request_id: nil)
    if connection.enabled? && !audiobook_storage_ready?
      return ItemBackup.new(status: :storage_not_ready, item: nil)
    end

    claim_result, media_import, poll_token = claim_backup_request(item_id, separate_edition: separate_edition, request_id: request_id)
    return ItemBackup.new(status: claim_result, item: media_import&.owned_library_item) unless claim_result.in?(%i[queued resume])

    item = media_import.owned_library_item
    backup_job = begin
      OwnedMediaBackupJob.perform_later(media_import.id, poll_token)
    rescue StandardError => e
      Rails.logger.error "[AudibleBackup] Failed to enqueue import ##{media_import.id}: #{e.class}"
      RemoteResult::Failed.new(e)
    end
    unless backup_job.respond_to?(:successfully_enqueued?) && backup_job.successfully_enqueued?
      if claim_result == :resume && media_import.upload&.pending?
        media_import.upload.update!(status: :failed, error_message: BACKUP_ENQUEUE_FAILURE)
      end
      media_import.mark_failed!(BACKUP_ENQUEUE_FAILURE, poll_token: poll_token)
      return ItemBackup.new(status: :enqueue_failed, item: item)
    end

    ItemBackup.new(status: claim_result, item: item)
  end

  def clear_stale_auth_state
    return unless connection.persisted?

    auth_state = connection.auth_state_snapshot
    return unless connection.stale_auth_state?

    connection.clear_auth_state_if_current!(auth_state)
    connection.reload
  end

  def storage_error
    connection.errors.full_messages.to_sentence
  end

  private

  def create_connection(attributes)
    connection.assign_attributes(attributes)
    connection.provider = "libation"
    connection.name = "Audible Backup"
    return :storage_not_ready if connection.enabled? && !audiobook_storage_ready?

    connection.save ? :saved : :invalid
  end

  def account_bound_backup_state?
    connection.owned_media_imports.cancellation_blocking.exists?
  end

  def endpoint_identity_change?(attributes)
    requested_url = attributes[:url]&.to_s&.strip&.delete_suffix("/")
    requested_url = OwnedLibraryConnection.default_libation_url if requested_url.blank?
    url_changed = attributes.key?(:url) && requested_url != connection.url
    token_changed = attributes[:bridge_token].present? && attributes[:bridge_token] != connection.bridge_token
    url_changed || token_changed
  end

  def invalidate_account_bound_catalog_after_auth!(completed_auth_state)
    connection.with_lock do
      connection.reload
      reset_account_bound_catalog!(clear_auth_state: connection.auth_state_snapshot == completed_auth_state)
    end
  end

  def reset_account_bound_catalog!(clear_auth_state: true)
    now = Time.current
    connection.owned_library_items.active.update_all(active: false, absent_since: now, updated_at: now)
    attributes = {
      companion_version: nil,
      provider_version: nil,
      last_synced_at: nil,
      last_sync_error: nil,
      backlog_backup_decided_at: nil,
      automatic_backup_enabled: false,
      automatic_backup_user: nil,
      automatic_backup_enabled_at: nil,
      next_scheduled_sync_at: connection.scheduled_sync_enabled? ? connection.next_scheduled_sync_time : nil
    }
    attributes.merge!(auth_session_id: nil, auth_login_url: nil, auth_expires_at: nil) if clear_auth_state
    connection.update!(attributes)
  end

  def claim_backup_request(item_id, separate_edition:, request_id:)
    connection.with_lock do
      connection.reload
      next [ :disabled, nil, nil ] unless connection.enabled?
      next [ :auth_active, nil, nil ] if connection.auth_active?
      next [ :sync_active, nil, nil ] if connection.sync_active?

      item = connection.owned_library_items.active.find(item_id)
      next [ :not_purchased, nil, nil ] unless item.purchased?

      local_resolution = OwnedLibraryBookMatcher.new.resolve(item)
      if local_resolution.matched?
        item.update!(book: local_resolution.book, file_path: local_resolution.book.file_path)
        next [ :already_in_library, nil, nil ]
      end
      next [ :local_conflict, nil, nil ] if local_resolution.conflict? && !separate_edition

      active_import = item.owned_media_imports.active.recent.first
      if active_import
        next [ :already_active, active_import, nil ] unless active_import.recoverable?
        next [ :already_active, active_import, nil ] if OwnedLibraryAutomationJob.backup_job_pending?(active_import.id)

        poll_token = OwnedMediaImport.generate_poll_token
        active_import.update!(poll_token: poll_token)
        next [ :resume, active_import, poll_token ]
      end

      reserved_import = item.owned_media_imports.recovery_reserved.recent.first
      if reserved_import
        upload = reserved_import.upload
        next [ :already_active, reserved_import, nil ] unless upload&.failed?

        poll_token = OwnedMediaImport.generate_poll_token
        upload.update!(status: :pending, error_message: nil)
        reserved_import.update!(
          status: "processing",
          completed_at: nil,
          error_message: nil,
          started_at: Time.current,
          upload_recovery_attempts: 0,
          poll_token: poll_token
        )
        next [ :resume, reserved_import, poll_token ]
      end

      poll_token = OwnedMediaImport.generate_poll_token
      admission = create_queued_import(item, poll_token: poll_token, separate_edition: local_resolution.conflict?, request_id: request_id)
      next [ admission, nil, nil ] if admission.is_a?(Symbol)

      [ :queued, admission, poll_token ]
    end
  end

  def claim_auth_start
    connection.with_lock do
      connection.reload
      next if active_operation? || account_bound_backup_state?

      token = "#{OwnedLibraryConnection::AUTH_START_PREFIX}#{SecureRandom.hex(16)}"
      connection.update!(
        auth_session_id: token,
        auth_login_url: nil,
        auth_expires_at: OwnedLibraryConnection::AUTH_START_TIMEOUT.from_now
      )
      token
    end
  end

  def persist_auth_session(auth_request_token, auth_session)
    connection.with_lock do
      connection.reload
      next false unless connection.auth_starting? &&
        ActiveSupport::SecurityUtils.secure_compare(connection.auth_session_id, auth_request_token)

      connection.update!(
        auth_session_id: auth_session.session_id,
        auth_login_url: auth_session.login_url,
        auth_expires_at: auth_session.expires_at
      )
      true
    end
  end

  def clear_auth_start_claim(auth_request_token)
    connection.with_lock do
      connection.reload
      next unless connection.auth_starting?
      next unless ActiveSupport::SecurityUtils.secure_compare(connection.auth_session_id, auth_request_token)

      connection.update!(auth_session_id: nil, auth_login_url: nil, auth_expires_at: nil)
    end
  end

  def auth_state_for_completion(proof)
    connection.with_lock do
      connection.reload
      next unless connection.auth_pending?
      next unless proof.call(connection.auth_session_id.to_s)

      connection.auth_state_snapshot
    end
  end

  def claim_completion(response_url, proof)
    connection.with_lock do
      connection.reload
      next :expired unless connection.auth_pending? && proof.call(connection.auth_session_id.to_s)
      next :wrong_marketplace unless self.class.same_marketplace?(connection.auth_login_url, response_url)

      pending_state = connection.auth_state_snapshot
      reset_account_bound_catalog!(clear_auth_state: false)
      connection.update!(
        auth_session_id: "#{OwnedLibraryConnection::AUTH_START_PREFIX}#{SecureRandom.hex(16)}",
        auth_login_url: nil,
        auth_expires_at: OwnedLibraryConnection::AUTH_START_TIMEOUT.from_now
      )
      CompletionClaim.new(pending_state: pending_state, auth_state: connection.auth_state_snapshot, endpoint: endpoint_identity)
    end
  end

  def finish_completion(claim)
    connection.with_lock do
      connection.reload
      connection.clear_auth_state! if connection.auth_state_snapshot == claim.auth_state
      SignInCompletion.new(status: endpoint_identity == claim.endpoint ? :connected : :expired, error: nil)
    end
  end

  def restore_completion(claim)
    connection.with_lock do
      connection.reload
      next unless connection.auth_state_snapshot == claim.auth_state

      connection.update!(
        auth_session_id: claim.pending_state.fetch(:session_id),
        auth_login_url: claim.pending_state.fetch(:login_url),
        auth_expires_at: claim.pending_state.fetch(:expires_at)
      )
    end
  end

  def abandon_completion(claim)
    connection.with_lock do
      connection.reload
      connection.clear_auth_state! if connection.auth_state_snapshot == claim.auth_state
    end
  end

  def endpoint_identity
    [ connection.url, connection.bridge_token ]
  end

  def reportable(value, secrets)
    return nil if value.nil? || value.include?("://") || secrets.any? { |secret| value.include?(secret) }

    value
  end

  def create_queued_import(item, poll_token:, separate_edition:, request_id:)
    attributes = { requested_by: @user, status: "queued", separate_edition: separate_edition, poll_token: poll_token }
    return item.owned_media_imports.create!(attributes) if request_id.blank?

    request = Request.find_by(id: request_id)
    return :request_unavailable unless request

    request.with_acquisition_transition_lock do |locked_request|
      next :request_mismatch unless item.book_id.present? && locked_request.book_id == item.book_id
      next :request_unavailable unless locked_request.upload_fulfillable?
      next :request_busy if locked_request.upload_cancellation_blocked? || locked_request.direct_acquisition_recovery_pending?

      item.owned_media_imports.create!(attributes.merge(request: locked_request))
    end
  rescue ActiveRecord::RecordNotFound
    :request_unavailable
  end

  def audiobook_storage_ready?
    OwnedMediaImportFileService.verify_filesystem_capabilities!
    true
  rescue OwnedMediaImportFileService::Error => e
    connection.errors.add(:base, "Audiobook storage is not ready: #{e.message}")
    false
  end
end
