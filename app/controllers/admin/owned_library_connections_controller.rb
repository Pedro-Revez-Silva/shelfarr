# frozen_string_literal: true

module Admin
  class OwnedLibraryConnectionsController < BaseController
    ITEMS_PER_PAGE = 50
    AUTOMATION_INTERVAL_OPTIONS = [
      [ "Every hour", 60 ],
      [ "Every 6 hours", 360 ],
      [ "Every 12 hours", 720 ],
      [ "Every 24 hours", 1_440 ],
      [ "Every 3 days", 4_320 ],
      [ "Weekly", 10_080 ]
    ].freeze

    before_action :prevent_sensitive_response_caching
    before_action :set_connection, except: [ :index, :create ]

    def index
      @connection = default_connection
      load_index_data
    end

    def create
      @connection = OwnedLibraryConnection.new(connection_params)
      @connection.provider = "libation"
      @connection.name = "Audible Backup"

      if @connection.enabled? && !audiobook_storage_ready?(@connection)
        load_index_data
        render :index, status: :unprocessable_entity
      elsif @connection.save
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          notice: "Audible Backup configuration was saved."
      else
        load_index_data
        render :index, status: :unprocessable_entity
      end
    end

    def update
      attributes = connection_params
      attributes = attributes.except(:bridge_token) if attributes[:bridge_token].blank?
      requested_enabled = ActiveModel::Type::Boolean.new.cast(
        attributes.fetch(:enabled, @connection.enabled?)
      )
      if requested_enabled && !audiobook_storage_ready?(@connection)
        load_index_data
        render :index, status: :unprocessable_entity
        return
      end

      update_result = @connection.with_lock do
        @connection.reload
        identity_changed = endpoint_identity_change?(attributes)
        if active_operation?
          :busy
        elsif identity_changed && pending_backup_queue?
          :pending_backups
        elsif @connection.update(attributes)
          reset_account_bound_catalog! if identity_changed
          :saved
        else
          :invalid
        end
      end

      if update_result == :busy
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          alert: "Wait for the current Libation operation or Audible sign-in to finish before changing its connection."
        return
      end
      if update_result == :pending_backups
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          alert: "Finish the queued Audible backups before changing the companion URL or token."
        return
      end

      if update_result == :saved
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          notice: "Audible Backup configuration was updated."
      else
        load_index_data
        render :index, status: :unprocessable_entity
      end
    end

    def test
      if active_operation?
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          alert: "Wait for the current Libation operation or Audible sign-in to finish before testing its connection."
        return
      end

      health = @connection.client.health
      version = @connection.client.version
      @connection.update!(
        companion_version: version.companion_version,
        provider_version: version.libation_version
      )

      status = health.is_a?(Hash) ? health["status"].presence : nil
      detail = [ version.companion_version, version.libation_version ].compact_blank.join(" / Libation ")
      message = "Connected to the Libation companion"
      message += " (#{detail})" if detail.present?
      message += "; status: #{status}" if status.present?
      redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"), notice: message
    rescue LibationCompanionClient::Error => e
      redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
        alert: "Could not connect to the Libation companion: #{e.message}"
    end

    def auth_start
      auth_request_token = claim_auth_start
      unless auth_request_token
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          alert: "Wait for current Libation work and queued Audible backups to finish before changing accounts."
        return
      end

      auth_session = @connection.client.start_auth(
        account: params[:account],
        locale: params[:locale]
      )
      if auth_session.authenticated
        clear_auth_start_claim(auth_request_token)
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          notice: "This Audible account is already authenticated in Libation."
        return
      end

      unless persist_auth_session(auth_request_token, auth_session)
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          alert: "The Audible sign-in request expired before Libation responded. Start again."
        return
      end

      @login_url = auth_session.login_url
      @auth_pending = true
      load_index_data
      render :index, status: :ok
    rescue ArgumentError, LibationCompanionClient::Error => e
      clear_auth_start_claim(auth_request_token) if auth_request_token
      redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
        alert: "Could not start Audible sign-in: #{e.message}"
    end

    def auth_complete
      auth_state = auth_state_for_completion(params[:auth_session_id])
      unless auth_state
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          alert: "The Audible sign-in session expired. Start again."
        return
      end

      @connection.client.complete_auth(
        session_id: auth_state.fetch(:session_id),
        response_url: params[:response_url]
      )
      @connection.clear_auth_state_if_current!(auth_state)
      redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
        notice: "Audible account connected through Libation."
    rescue ArgumentError, LibationCompanionClient::Error => e
      redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
        alert: "Could not complete Audible sign-in: #{e.message}"
    end

    def sync
      result = OwnedLibrarySyncRequest.call(connection: @connection, mode: :manual)
      if result.status == :disabled
        redirect_to admin_owned_library_connections_path(anchor: "overview"),
          alert: "Enable Audible Backup before syncing."
        return
      end
      if result.status == :auth_active
        redirect_to admin_owned_library_connections_path(anchor: "overview"),
          alert: "Finish the current Audible sign-in before syncing the library."
        return
      end
      if result.status == :backups_active
        redirect_to admin_owned_library_connections_path(anchor: "overview"),
          alert: "Wait for queued Audible backups to finish before syncing the library."
        return
      end
      if result.status == :active
        redirect_to admin_owned_library_connections_path(anchor: "overview"),
          notice: "An Audible library sync is already queued or running. This page will update automatically."
        return
      end
      if result.status == :enqueue_failed
        redirect_to admin_owned_library_connections_path(anchor: "overview"),
          alert: "Shelfarr could not queue the Audible library sync. Try again."
        return
      end

      notice = case result.status
      when :recovery
        "Audible library sync recovery queued. This page will update automatically."
      when :resume
        "Audible library sync status check queued. This page will update automatically."
      else
        "Audible library sync queued. This page will update automatically."
      end
      redirect_to admin_owned_library_connections_path(anchor: "overview"), notice: notice
    end

    def backup_existing
      OwnedMediaImportFileService.verify_filesystem_capabilities!
      result = OwnedLibraryBacklogBackup.call(
        connection: @connection,
        requested_by: Current.user,
        confirmed: params[:confirm_existing_library_backup] == "1"
      )

      notice = if result.queued?
        "#{result.queued_count} existing Audible #{'purchase'.pluralize(result.queued_count)} added to the background backup queue. Libation will process one title at a time."
      else
        "No unattempted purchased audiobooks are currently eligible for the existing-library backup."
      end
      redirect_to admin_owned_library_connections_path(anchor: "overview"), notice: notice
    rescue OwnedLibraryBacklogBackup::ConfirmationRequired => e
      redirect_to admin_owned_library_connections_path(anchor: "overview"), alert: e.message
    rescue OwnedLibraryBacklogBackup::InvalidRequester,
      OwnedLibraryBacklogBackup::ConnectionUnavailable => e
      redirect_to admin_owned_library_connections_path(anchor: "overview"), alert: e.message
    rescue OwnedMediaImportFileService::Error => e
      redirect_to admin_owned_library_connections_path(anchor: "overview"),
        alert: "Audiobook storage is not ready: #{e.message}"
    rescue ActiveRecord::RecordNotUnique
      redirect_to admin_owned_library_connections_path(anchor: "overview"),
        alert: "The existing-library backup changed while it was being queued. Refresh and review the current eligible count."
    end

    def dismiss_existing_backup
      @connection.update!(backlog_backup_decided_at: Time.current)
      redirect_to admin_owned_library_connections_path(tab: "automation", anchor: "automation"),
        notice: "Existing-library backup skipped for now. You can start it later from Automation."
    end

    def update_automation
      attributes = automation_params.to_h.symbolize_keys
      scheduled_sync_enabled = ActiveModel::Type::Boolean.new.cast(
        attributes[:scheduled_sync_enabled]
      )
      automatic_backup_enabled = ActiveModel::Type::Boolean.new.cast(
        attributes[:automatic_backup_enabled]
      )
      if automatic_backup_enabled && !audiobook_storage_ready?(@connection)
        redirect_to admin_owned_library_connections_path(tab: "automation", anchor: "automation"),
          alert: @connection.errors.full_messages.to_sentence
        return
      end

      update_result = @connection.with_lock do
        @connection.reload
        next :disabled unless @connection.enabled?
        if automatic_backup_enabled && !scheduled_sync_enabled &&
            !@connection.scheduled_sync_enabled?
          next :schedule_required
        end

        automatic_backup_enabled = false unless scheduled_sync_enabled
        attributes[:scheduled_sync_enabled] = scheduled_sync_enabled
        attributes[:automatic_backup_enabled] = automatic_backup_enabled
        if automatic_backup_enabled && @connection.last_synced_at.blank?
          next :baseline_required
        end
        if automatic_backup_enabled && !@connection.automatic_backup_enabled? && @connection.sync_active?
          next :sync_active
        end

        if automatic_backup_enabled
          unless @connection.automatic_backup_ready?
            attributes[:automatic_backup_user] = Current.user
          end
          attributes[:automatic_backup_enabled_at] =
            @connection.automatic_backup_enabled_at.presence || Time.current
        else
          attributes[:automatic_backup_user] = nil
          attributes[:automatic_backup_enabled_at] = nil
        end

        @connection.update(attributes) ? :saved : :invalid
      end

      case update_result
      when :disabled
        redirect_to admin_owned_library_connections_path(tab: "automation", anchor: "automation"),
          alert: "Enable Audible Backup before configuring automation."
      when :schedule_required
        redirect_to admin_owned_library_connections_path(tab: "automation", anchor: "automation"),
          alert: "Automatic backups require scheduled library sync. Enable both options and save again."
      when :baseline_required
        redirect_to admin_owned_library_connections_path(tab: "automation", anchor: "automation"),
          alert: "Run an initial library sync before enabling automatic backups. This establishes the existing-library baseline."
      when :sync_active
        redirect_to admin_owned_library_connections_path(tab: "automation", anchor: "automation"),
          alert: "Wait for the current Audible library sync to finish before enabling automatic backups."
      when :saved
        notice = if scheduled_sync_enabled
          automatic_backup_enabled ?
            "Audible automation updated. The next successful sync will refresh the no-download baseline; later purchases can be backed up automatically." :
            "Scheduled Audible library sync enabled. Automatic backups remain off."
        else
          "Audible automation disabled. Manual sync and backup remain available."
        end
        redirect_to admin_owned_library_connections_path(tab: "automation", anchor: "automation"), notice: notice
      else
        load_index_data
        render :index, status: :unprocessable_entity
      end
    end

    def backup
      if @connection.enabled? && !audiobook_storage_ready?(@connection)
        redirect_back fallback_location: admin_owned_library_connections_path,
          alert: @connection.errors.full_messages.to_sentence
        return
      end

      claim_result, media_import, poll_token = claim_backup_request
      if claim_result == :disabled
        redirect_back fallback_location: admin_owned_library_connections_path,
          alert: "Enable Audible Backup before backing up a title."
        return
      end
      if claim_result == :auth_active
        redirect_back fallback_location: admin_owned_library_connections_path,
          alert: "Finish the current Audible sign-in before queueing backups."
        return
      end
      if claim_result == :sync_active
        redirect_back fallback_location: admin_owned_library_connections_path,
          alert: "Wait for the Audible library sync to finish before queueing backups."
        return
      end
      if claim_result == :not_purchased
        redirect_back fallback_location: admin_owned_library_connections_path,
          alert: "Only titles confirmed as purchased are eligible for backup."
        return
      end
      if claim_result == :already_in_library
        redirect_back fallback_location: admin_owned_library_connections_path,
          notice: "This title is already available in the Shelfarr library. Its existing file was preserved."
        return
      end
      if claim_result == :local_conflict
        redirect_back fallback_location: admin_owned_library_connections_path,
          alert: "A local audiobook has the same title, but Shelfarr could not confirm the identity safely. The backup was not queued."
        return
      end
      if claim_result == :request_mismatch
        redirect_back fallback_location: admin_owned_library_connections_path,
          alert: "The selected request does not match this Audible title."
        return
      end
      if claim_result == :request_unavailable
        redirect_back fallback_location: admin_owned_library_connections_path,
          alert: "This request is no longer open for Audible fulfillment."
        return
      end
      if claim_result == :request_busy
        redirect_back fallback_location: admin_owned_library_connections_path,
          alert: "This request already has an acquisition or recovery in progress."
        return
      end
      if claim_result == :already_active
        redirect_back fallback_location: admin_owned_library_connections_path,
          notice: "This Audible backup is already queued or running. The Library will update automatically."
        return
      end

      item = media_import.owned_library_item
      backup_job = begin
        OwnedMediaBackupJob.perform_later(media_import.id, poll_token)
      rescue StandardError => e
        Rails.logger.error "[AudibleBackup] Failed to enqueue import ##{media_import.id}: #{e.class}"
        false
      end
      unless enqueue_succeeded?(backup_job)
        if claim_result == :resume && media_import.upload&.pending?
          media_import.upload.update!(
            status: :failed,
            error_message: "Shelfarr could not queue the Libation backup"
          )
        end
        media_import.mark_failed!(
          "Shelfarr could not queue the Libation backup",
          poll_token: poll_token
        )
        redirect_back fallback_location: admin_owned_library_connections_path,
          alert: "Shelfarr could not queue the Libation backup. Try again."
        return
      end

      redirect_back fallback_location: admin_owned_library_connections_path,
        notice: claim_result == :resume ?
          "Backup status check for '#{item.display_title}' queued." :
          "Backup of '#{item.display_title}' queued through Libation."
    rescue ActiveRecord::RecordInvalid => e
      redirect_back fallback_location: admin_owned_library_connections_path,
        alert: e.record.errors.full_messages.to_sentence
    rescue ActiveRecord::RecordNotUnique
      redirect_back fallback_location: admin_owned_library_connections_path,
        alert: "A backup is already active for this library item."
    end

    private

    def prevent_sensitive_response_caching
      no_store
    end

    def set_connection
      @connection = OwnedLibraryConnection.find(params[:id])
    end

    def default_connection
      OwnedLibraryConnection.for_provider("libation").first_or_initialize do |connection|
        connection.name = "Audible Backup"
        connection.url = OwnedLibraryConnection.default_libation_url
        connection.allow_private_network = true
        connection.enabled = false
      end
    end

    def connection_params
      params.require(:owned_library_connection).permit(
        :url, :bridge_token, :enabled, :allow_private_network, :timeout_seconds
      )
    end

    def automation_params
      params.require(:owned_library_connection).permit(
        :scheduled_sync_enabled,
        :scheduled_sync_interval_minutes,
        :automatic_backup_enabled
      )
    end

    def load_index_data
      load_library_items
      load_library_summary
      @accounts = []
      @audible_connected = @library_total_items.positive? ||
        @connection.last_synced_at.present? || @connection.sync_active?
      clear_stale_auth_state
      @auth_starting = @connection.persisted? && @connection.auth_starting?
      @auth_pending ||= @connection.persisted? && @connection.auth_pending?
      @auth_active = @auth_starting || @auth_pending
      @login_url ||= @connection.auth_login_url if @auth_pending

      return unless @connection.persisted? && @connection.enabled?
      if @auth_active
        @companion_busy = true
        return
      end
      if active_operation?
        @companion_busy = true
        return
      end

      @accounts = @connection.client.accounts
      # A successful live account response is authoritative. Cached titles are
      # only an availability hint while Libation is busy or unreachable.
      @audible_connected = @accounts.any?(&:authenticated)
      @companion_available = true
    rescue LibationCompanionClient::BusyError
      @companion_busy = true
    rescue LibationCompanionClient::Error => e
      @companion_error = e.message
    end

    def load_library_items
      @query = params[:q].to_s.strip.first(200)
      @page = [ params[:page].to_i, 1 ].max
      scope = if @connection.persisted?
        @connection.owned_library_items
          .includes(:book)
          .active
          .alphabetical
      else
        OwnedLibraryItem.none
      end

      if @query.present?
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(@query.downcase)}%"
        scope = scope.where(
          "LOWER(owned_library_items.title) LIKE :pattern OR " \
            "LOWER(CAST(owned_library_items.authors AS TEXT)) LIKE :pattern",
          pattern: pattern
        )
      end

      @total_items = scope.count
      @total_pages = [ (@total_items.to_f / ITEMS_PER_PAGE).ceil, 1 ].max
      @page = @total_pages if @page > @total_pages
      @items = scope.offset((@page - 1) * ITEMS_PER_PAGE).limit(ITEMS_PER_PAGE).to_a
      OwnedLibraryItem.preload_latest_imports(@items)
    end

    def active_operation?
      @connection.auth_active? || @connection.sync_active? ||
        @connection.owned_media_imports.active.exists?
    end

    def pending_backup_queue?
      @connection.owned_media_imports.pending.exists?
    end

    def endpoint_identity_change?(attributes)
      requested_url = attributes[:url]&.to_s&.strip&.delete_suffix("/")
      url_changed = requested_url.present? && requested_url != @connection.url
      token_changed = attributes[:bridge_token].present? &&
        attributes[:bridge_token] != @connection.bridge_token
      url_changed || token_changed
    end

    def reset_account_bound_catalog!
      now = Time.current
      @connection.owned_library_items.active.update_all(
        active: false,
        absent_since: now,
        updated_at: now
      )
      @connection.update!(
        auth_session_id: nil,
        auth_login_url: nil,
        auth_expires_at: nil,
        companion_version: nil,
        provider_version: nil,
        last_synced_at: nil,
        last_sync_error: nil,
        backlog_backup_decided_at: nil,
        automatic_backup_enabled: false,
        automatic_backup_user: nil,
        automatic_backup_enabled_at: nil,
        next_scheduled_sync_at: @connection.scheduled_sync_enabled? ?
          @connection.next_scheduled_sync_time : nil
      )
    end

    def load_library_summary
      scope = @connection.persisted? ? @connection.owned_library_items.active : OwnedLibraryItem.none
      @library_total_items = scope.count
      ownership_counts = scope.group(:ownership_type).count
      @purchased_items = ownership_counts.fetch("purchased", 0)
      @subscription_items = ownership_counts.fetch("subscription", 0)
      @active_backup_counts = if @connection.persisted?
        @connection.owned_media_imports.active.group(:status).count
      else
        {}
      end
      @active_backup_total = @active_backup_counts.values.sum
      load_backlog_backup_summary
      @sync_recoverable = @connection.persisted? && recoverable_sync?
      @sync_state = if @connection.queued?
        "queued"
      elsif @connection.syncing?
        "syncing"
      elsif @connection.failed?
        "failed"
      elsif @connection.last_synced_at.present?
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
      return unless @connection.persisted? && @connection.last_synced_at.present?

      @backlog_backup_available = OwnedLibraryBacklogBackup.potential_candidates?(
        connection: @connection
      )
      @backlog_backup_prompt = !@connection.backlog_backup_decided? &&
        @backlog_backup_available

      backlog_scope = @connection.owned_media_imports.where(status: "pending").or(
        @connection.owned_media_imports.where.not(dispatched_at: nil)
      )
      @backlog_backup_counts = backlog_scope.group(:status).count
      @backlog_backup_total = @backlog_backup_counts.values.sum
      @backlog_backup_remaining = @backlog_backup_counts.values_at(
        "pending", *OwnedMediaImport::ACTIVE_STATUSES
      ).compact.sum
      @backlog_backup_processed = @backlog_backup_counts.values_at(
        *OwnedMediaImport::TERMINAL_STATUSES
      ).compact.sum
    end

    def claim_backup_request
      @connection.with_lock do
        @connection.reload
        next [ :disabled, nil, nil ] unless @connection.enabled?
        next [ :auth_active, nil, nil ] if @connection.auth_active?
        next [ :sync_active, nil, nil ] if @connection.sync_active?

        item = @connection.owned_library_items.active.find(params[:item_id])
        next [ :not_purchased, nil, nil ] unless item.purchased?

        local_resolution = OwnedLibraryBookMatcher.new.resolve(item)
        if local_resolution.matched?
          item.update!(
            book: local_resolution.book,
            file_path: local_resolution.book.file_path
          )
          next [ :already_in_library, nil, nil ]
        end
        if local_resolution.conflict? && params[:separate_edition] != "1"
          next [ :local_conflict, nil, nil ]
        end

        active_import = item.owned_media_imports.active.recent.first
        if active_import
          unless active_import.recoverable?
            next [ :already_active, active_import, nil ]
          end
          if OwnedLibraryAutomationJob.backup_job_pending?(active_import.id)
            next [ :already_active, active_import, nil ]
          end

          poll_token = OwnedMediaImport.generate_poll_token
          active_import.update!(poll_token: poll_token)
          next [
            :resume,
            active_import,
            poll_token
          ]
        end

        reserved_import = item.owned_media_imports.recovery_reserved.recent.first
        if reserved_import
          upload = reserved_import.upload
          unless upload&.failed?
            next [ :already_active, reserved_import, nil ]
          end

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
        admission = create_queued_import(
          item,
          poll_token: poll_token,
          separate_edition: local_resolution.conflict?
        )
        next [ admission, nil, nil ] if admission.is_a?(Symbol)

        [
          :queued,
          admission,
          poll_token
        ]
      end
    end

    def recoverable_sync?
      return false unless @connection.sync_active?

      @connection.updated_at.blank? ||
        @connection.updated_at <= OwnedLibrarySyncJob::START_GRACE_PERIOD.ago
    end

    def claim_auth_start
      @connection.with_lock do
        @connection.reload
        next if active_operation? || pending_backup_queue?

        token = "#{OwnedLibraryConnection::AUTH_START_PREFIX}#{SecureRandom.hex(16)}"
        @connection.update!(
          auth_session_id: token,
          auth_login_url: nil,
          auth_expires_at: OwnedLibraryConnection::AUTH_START_TIMEOUT.from_now
        )
        token
      end
    end

    def persist_auth_session(auth_request_token, auth_session)
      @connection.with_lock do
        @connection.reload
        next false unless @connection.auth_starting? &&
          ActiveSupport::SecurityUtils.secure_compare(
            @connection.auth_session_id,
            auth_request_token
          )

        @connection.update!(
          auth_session_id: auth_session.session_id,
          auth_login_url: auth_session.login_url,
          auth_expires_at: auth_session.expires_at
        )
        true
      end
    end

    def clear_auth_start_claim(auth_request_token)
      @connection.with_lock do
        @connection.reload
        next unless @connection.auth_starting?
        next unless ActiveSupport::SecurityUtils.secure_compare(
          @connection.auth_session_id,
          auth_request_token
        )

        @connection.update!(auth_session_id: nil, auth_login_url: nil, auth_expires_at: nil)
      end
    end

    def auth_state_for_completion(submitted_session_id)
      submitted_session_id = submitted_session_id.to_s
      return if submitted_session_id.blank?

      @connection.with_lock do
        @connection.reload
        current_session_id = @connection.auth_session_id.to_s
        next unless @connection.auth_pending?
        next unless current_session_id.bytesize == submitted_session_id.bytesize
        next unless ActiveSupport::SecurityUtils.secure_compare(current_session_id, submitted_session_id)

        @connection.auth_state_snapshot
      end
    end

    def clear_stale_auth_state
      return unless @connection.persisted?

      auth_state = @connection.auth_state_snapshot
      return unless @connection.stale_auth_state?

      @connection.clear_auth_state_if_current!(auth_state)
      @connection.reload
    end

    def create_queued_import(item, poll_token:, separate_edition:)
      attributes = {
        requested_by: Current.user,
        status: "queued",
        separate_edition: separate_edition,
        poll_token: poll_token
      }
      request_id = params[:request_id].presence
      return item.owned_media_imports.create!(attributes) if request_id.blank?

      request = Request.find_by(id: request_id)
      return :request_unavailable unless request

      request.with_acquisition_transition_lock do |locked_request|
        unless item.book_id.present? && locked_request.book_id == item.book_id
          next :request_mismatch
        end
        next :request_unavailable unless locked_request.upload_fulfillable?
        if locked_request.upload_cancellation_blocked? ||
            locked_request.direct_acquisition_recovery_pending?
          next :request_busy
        end

        item.owned_media_imports.create!(attributes.merge(request: locked_request))
      end
    rescue ActiveRecord::RecordNotFound
      :request_unavailable
    end

    def enqueue_succeeded?(job)
      job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?
    end

    def audiobook_storage_ready?(record)
      OwnedMediaImportFileService.verify_filesystem_capabilities!
      true
    rescue OwnedMediaImportFileService::Error => e
      record.errors.add(:base, "Audiobook storage is not ready: #{e.message}")
      false
    end
  end
end
