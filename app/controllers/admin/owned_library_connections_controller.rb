# frozen_string_literal: true

module Admin
  class OwnedLibraryConnectionsController < BaseController
    ITEMS_PER_PAGE = OwnedLibraryConnectionWorkflow::ITEMS_PER_PAGE
    AUTOMATION_INTERVAL_OPTIONS = OwnedLibraryConnectionWorkflow::AUTOMATION_INTERVAL_OPTIONS

    before_action :prevent_sensitive_response_caching
    before_action :set_connection, except: [ :index, :create ]

    def index
      @connection = OwnedLibraryConnectionWorkflow.default_connection
      load_index_data
    end

    def create
      @connection = OwnedLibraryConnection.new
      if workflow.save_connection(connection_params) == :saved
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          notice: "Audible Backup configuration was saved."
      else
        load_index_data
        render :index, status: :unprocessable_entity
      end
    end

    def update
      case workflow.save_connection(connection_params)
      when :busy
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          alert: "Wait for the current Libation operation or Audible sign-in to finish before changing its connection."
      when :pending_backups
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          alert: "Finish queued Audible backups and resolve recoverable Audible backups before changing the companion URL or token."
      when :saved
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          notice: "Audible Backup configuration was updated."
      else
        load_index_data
        render :index, status: :unprocessable_entity
      end
    end

    def test
      result = workflow.test_connection
      case result.status
      when :busy
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          alert: "Wait for the current Libation operation or Audible sign-in to finish before testing its connection."
      when :failed
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          alert: "Could not connect to the Libation companion: #{result.error.message}"
      else
        detail = [ result.companion_version, result.libation_version ].compact_blank.join(" / Libation ")
        message = "Connected to the Libation companion"
        message += " (#{detail})" if detail.present?
        message += "; status: #{result.health_status}" if result.health_status.present?
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"), notice: message
      end
    end

    def auth_start
      result = workflow.start_sign_in(account: params[:account], locale: params[:locale], reregister: params[:reregister])
      case result.status
      when :busy
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          alert: "Wait for current Libation work and queued Audible backups to finish, and resolve recoverable Audible backups, before changing accounts."
      when :authenticated
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          notice: "This Audible account is already authenticated in Libation."
      when :expired
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          alert: "The Audible sign-in request expired before Libation responded. Start again."
      when :failed
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          alert: "Could not start Audible sign-in: #{result.error.message}"
      else
        @login_url = result.login_url
        load_index_data(auth_pending: true)
        render :index, status: :ok
      end
    end

    def auth_complete
      submitted_session_id = params[:auth_session_id].to_s
      result = workflow.complete_sign_in(response_url: params[:response_url]) do |current_session_id|
        submitted_session_id.present? &&
          current_session_id.bytesize == submitted_session_id.bytesize &&
          ActiveSupport::SecurityUtils.secure_compare(current_session_id, submitted_session_id)
      end
      case result.status
      when :expired
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          alert: "The Audible sign-in session expired. Start again."
      when :failed
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          alert: "Could not complete Audible sign-in: #{result.error.message}"
      else
        redirect_to admin_owned_library_connections_path(tab: "connection", anchor: "connection"),
          notice: "Audible account connected through Libation."
      end
    end

    def sync
      result = workflow.sync
      flash_type, message = case result.status
      when :disabled then [ :alert, "Enable Audible Backup before syncing." ]
      when :auth_active then [ :alert, "Finish the current Audible sign-in before syncing the library." ]
      when :backups_active then [ :alert, "Wait for queued Audible backups to finish before syncing the library." ]
      when :active then [ :notice, "An Audible library sync is already queued or running. This page will update automatically." ]
      when :enqueue_failed then [ :alert, "Shelfarr could not queue the Audible library sync. Try again." ]
      when :recovery then [ :notice, "Audible library sync recovery queued. This page will update automatically." ]
      when :resume then [ :notice, "Audible library sync status check queued. This page will update automatically." ]
      else [ :notice, "Audible library sync queued. This page will update automatically." ]
      end
      redirect_to admin_owned_library_connections_path(anchor: "overview"), flash_type => message
    end

    def backup_existing
      result = workflow.back_up_existing(confirmed: params[:confirm_existing_library_backup] == "1")
      flash_type, message = case result.status
      when :queued
        [ :notice, "#{result.queued_count} existing Audible #{'purchase'.pluralize(result.queued_count)} added to the background backup queue. Libation will process one title at a time." ]
      when :none_eligible
        [ :notice, "No unattempted purchased audiobooks are currently eligible for the existing-library backup." ]
      when :storage_not_ready
        [ :alert, "Audiobook storage is not ready: #{result.error.message}" ]
      when :changed
        [ :alert, "The existing-library backup changed while it was being queued. Refresh and review the current eligible count." ]
      else
        [ :alert, result.error.message ]
      end
      redirect_to admin_owned_library_connections_path(anchor: "overview"), flash_type => message
    end

    def dismiss_existing_backup
      workflow.dismiss_existing_backup
      redirect_to admin_owned_library_connections_path(tab: "automation", anchor: "automation"),
        notice: "Existing-library backup skipped for now. You can start it later from Automation."
    end

    def update_automation
      result = workflow.update_automation(automation_params)
      automation_path = admin_owned_library_connections_path(tab: "automation", anchor: "automation")
      case result.status
      when :storage_not_ready
        redirect_to automation_path, alert: workflow.storage_error
      when :disabled
        redirect_to automation_path, alert: "Enable Audible Backup before configuring automation."
      when :schedule_required
        redirect_to automation_path, alert: "Automatic backups require scheduled library sync. Enable both options and save again."
      when :baseline_required
        redirect_to automation_path, alert: "Run an initial library sync before enabling automatic backups. This establishes the existing-library baseline."
      when :sync_active
        redirect_to automation_path, alert: "Wait for the current Audible library sync to finish before enabling automatic backups."
      when :saved
        notice = if result.scheduled_sync_enabled
          result.automatic_backup_enabled ?
            "Audible automation updated. The next successful sync will refresh the no-download baseline; later purchases can be backed up automatically." :
            "Scheduled Audible library sync enabled. Automatic backups remain off."
        else
          "Audible automation disabled. Manual sync and backup remain available."
        end
        redirect_to automation_path, notice: notice
      else
        load_index_data
        render :index, status: :unprocessable_entity
      end
    end

    def backup
      result = workflow.back_up_item(
        item_id: params[:item_id],
        separate_edition: params[:separate_edition] == "1",
        request_id: params[:request_id].presence
      )
      flash_type, message = backup_message(result)
      redirect_back fallback_location: admin_owned_library_connections_path, flash_type => message
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

    def workflow
      @workflow ||= OwnedLibraryConnectionWorkflow.new(@connection, user: Current.user)
    end

    def connection_params
      params.require(:owned_library_connection).permit(*OwnedLibraryConnectionWorkflow::CONNECTION_ATTRIBUTES)
    end

    def automation_params
      params.require(:owned_library_connection).permit(*OwnedLibraryConnectionWorkflow::AUTOMATION_ATTRIBUTES)
    end

    def load_index_data(auth_pending: false)
      catalogue = workflow.catalogue(query: params[:q], page: params[:page])
      @query = catalogue.query
      @page = catalogue.page
      @total_items = catalogue.total_items
      @total_pages = catalogue.total_pages
      @items = catalogue.items

      summary = workflow.summary(auth_pending: auth_pending)
      @accounts = summary.accounts
      @audible_connected = summary.audible_connected?
      @auth_starting = summary.auth_starting?
      @auth_pending = summary.auth_pending?
      @auth_active = summary.auth_active?
      @login_url ||= summary.login_url
      @companion_busy = true if summary.companion_busy?
      @companion_available = true if summary.companion_available?
      @companion_error = summary.companion_error
      @library_total_items = summary.library_total_items
      @purchased_items = summary.purchased_items
      @subscription_items = summary.subscription_items
      @active_backup_counts = summary.active_backup_counts
      @active_backup_total = summary.active_backup_total
      @backlog_backup_available = summary.backlog_backup_available
      @backlog_backup_prompt = summary.backlog_backup_prompt
      @backlog_backup_counts = summary.backlog_backup_counts
      @backlog_backup_total = summary.backlog_backup_total
      @backlog_backup_remaining = summary.backlog_backup_remaining
      @backlog_backup_processed = summary.backlog_backup_processed
      @sync_recoverable = summary.sync_recoverable
      @sync_state = summary.sync_state
    end

    def backup_message(result)
      title = result.item&.display_title
      case result.status
      when :storage_not_ready then [ :alert, workflow.storage_error ]
      when :disabled then [ :alert, "Enable Audible Backup before backing up a title." ]
      when :auth_active then [ :alert, "Finish the current Audible sign-in before queueing backups." ]
      when :sync_active then [ :alert, "Wait for the Audible library sync to finish before queueing backups." ]
      when :not_purchased then [ :alert, "Only titles confirmed as purchased are eligible for backup." ]
      when :already_in_library then [ :notice, "This title is already available in the Shelfarr library. Its existing file was preserved." ]
      when :local_conflict then [ :alert, "A local audiobook has the same title, but Shelfarr could not confirm the identity safely. The backup was not queued." ]
      when :request_mismatch then [ :alert, "The selected request does not match this Audible title." ]
      when :request_unavailable then [ :alert, "This request is no longer open for Audible fulfillment." ]
      when :request_busy then [ :alert, "This request already has an acquisition or recovery in progress." ]
      when :already_active then [ :notice, "This Audible backup is already queued or running. The Library will update automatically." ]
      when :enqueue_failed then [ :alert, "Shelfarr could not queue the Libation backup. Try again." ]
      when :resume then [ :notice, "Backup status check for '#{title}' queued." ]
      else [ :notice, "Backup of '#{title}' queued through Libation." ]
      end
    end
  end
end
