# frozen_string_literal: true

class WebPreview::Admin::AudibleBackupController < WebPreview::Admin::BaseController
  TEXTS = %w[url bridge_token].freeze
  SWITCHES = %w[enabled allow_private_network].freeze
  SWITCH_VALUES = [ true, false ].freeze
  FIELD_LABELS = { "url" => "Companion address", "bridge_token" => "Bridge token", "timeout_seconds" => "Request timeout" }.freeze
  IDENTIFIER = /\A[1-9]\d{0,18}\z/

  class Malformed < StandardError; end
  class Forbidden < StandardError; end

  rescue_from Malformed, with: ->(error) { render_error("invalid_request", :bad_request, message: error.message) }
  rescue_from Forbidden, with: -> { render_error("not_found", :not_found) }
  rescue_from ActionDispatch::Http::Parameters::ParseError, with: -> { render_error("invalid_request", :bad_request) }

  before_action :require_acting_administrator, except: %i[show catalogue]
  before_action :require_saved_connection, except: %i[show catalogue update_connection]

  def show
    render json: answer
  end

  def catalogue
    query = params[:q]
    page = params[:page]
    raise Malformed, "Send the filter as text" unless [ query, page ].all? { |value| value.nil? || value.is_a?(String) }
    raise Malformed, "Send the page as a positive number" unless page.blank? || page.match?(/\A[1-9]\d{0,8}\z/)

    render json: { account: web_preview_account_id, **presenter.catalogue(workflow.catalogue(query: query, page: page)) }
  end

  def update_connection
    status = workflow.save_connection(submitted_connection)
    return render_rejected if status.in?(%i[invalid storage_not_ready])

    render json: answer(outcome: case status
    when :busy then failure("Wait for the current Libation operation or Audible sign-in to finish before changing the connection.")
    when :pending_backups then failure("Finish queued Audible backups and resolve recoverable ones before changing the companion address or token.")
    else success("Audible backup connection saved.")
    end)
  end

  def test
    result = workflow.test_connection
    outcome = case result.status
    when :busy then failure("Wait for the current Libation operation or Audible sign-in to finish before testing the connection.")
    when :failed then failure("Could not connect to the Libation companion: #{presenter.redact(result.error.message)}")
    else
      detail = [ result.companion_version, result.libation_version ].compact_blank.join(" / Libation ")
      success(presenter.redact([ "Connected to the Libation companion", (" (#{detail})" if detail.present?), ("; status: #{result.health_status}" if result.health_status.present?), "." ].join))
    end
    render json: answer(outcome: outcome, tested: true)
  end

  def start_sign_in
    account, locale = body.values_at("account", "locale")
    reregister = body.fetch("reregister", false)
    raise Malformed, "Send the account and marketplace as text" unless account.is_a?(String) && locale.is_a?(String)
    raise Malformed, "Send replace registration as true or false" unless SWITCH_VALUES.include?(reregister)

    result = workflow.start_sign_in(account: account, locale: locale, reregister: reregister)
    outcome = case result.status
    when :busy then failure("Wait for current Libation work and queued Audible backups to finish, and resolve recoverable ones, before changing accounts.")
    when :authenticated then success("This Audible account is already signed in through Libation.")
    when :expired then failure("The Audible sign-in request expired before Libation answered. Start again.")
    when :failed then failure("Could not start Audible sign-in: #{presenter.redact(result.error.message)}")
    else success("Open the Audible sign-in, then paste the address it ends on.")
    end
    render json: answer(outcome: outcome, auth_pending: result.status == :pending)
  end

  def complete_sign_in
    token, response_url = body.values_at("sign_in_token", "response_url")
    raise Malformed, "Send the sign-in token and the final address as text" unless token.is_a?(String) && response_url.is_a?(String)

    unless WebPreview::AudibleBackupJson.safe_sign_in_link(response_url.strip)
      return render json: answer(outcome: failure("Paste the full https address the Amazon or Audible tab ends on. Nothing was sent to Libation."))
    end

    if connection.auth_pending? && !OwnedLibraryConnectionWorkflow.same_marketplace?(connection.auth_login_url, response_url)
      return render json: answer(outcome: failure("That address is from a different Audible marketplace than this sign-in. Paste the address from the tab this sign-in opened. Nothing was sent to Libation."))
    end

    result = workflow.complete_sign_in(response_url: response_url) do |session_id|
      WebPreview::AudibleBackupJson.sign_in_token_matches?(connection, Current.user, session_id, token)
    end
    outcome = case result.status
    when :expired then failure("This Audible sign-in has expired or was already used. Start again.")
    when :failed then failure("Could not complete Audible sign-in: #{presenter.redact(result.error.message)}")
    else success("Audible account connected through Libation.")
    end
    render json: answer(outcome: outcome)
  end

  def sync
    result = workflow.sync
    outcome = case result.status
    when :disabled then failure("Turn on Audible backup before syncing.")
    when :auth_active then failure("Finish the current Audible sign-in before syncing the library.")
    when :backups_active then failure("Wait for queued Audible backups to finish before syncing the library.")
    when :active then success("An Audible library sync is already queued or running.")
    when :enqueue_failed then failure("Shelfarr could not queue the Audible library sync. Try again.")
    when :recovery then success("Audible library sync recovery queued.")
    when :resume then success("Audible library sync status check queued.")
    else success("Audible library sync queued.")
    end
    render json: answer(outcome: outcome)
  end

  def back_up_existing
    raise Malformed, "Confirm the existing-library backup" unless body["confirm"] == true

    result = workflow.back_up_existing(confirmed: true)
    outcome = case result.status
    when :queued then success("#{result.queued_count} existing Audible #{'purchase'.pluralize(result.queued_count)} added to the background backup queue. Libation processes one title at a time.")
    when :none_eligible then success("No unattempted purchased audiobooks are eligible for the existing-library backup.")
    when :storage_not_ready then failure("Audiobook storage is not ready: #{result.error.message}")
    when :changed then failure("The existing-library backup changed while it was being queued. Review the current count and try again.")
    else failure(result.error.message)
    end
    render json: answer(outcome: outcome)
  end

  def dismiss_existing_backup
    workflow.dismiss_existing_backup
    render json: answer(outcome: success("Existing-library backup skipped for now. You can start it later under Automation."))
  end

  def update_automation
    result = workflow.update_automation(submitted_automation)
    outcome = case result.status
    when :storage_not_ready then failure(workflow.storage_error)
    when :disabled then failure("Turn on Audible backup before configuring automation.")
    when :schedule_required then failure("Automatic backups need scheduled library sync. Turn both on and save again.")
    when :baseline_required then failure("Run a first library sync before turning on automatic backups. It sets the existing-library baseline.")
    when :sync_active then failure("Wait for the current Audible library sync to finish before turning on automatic backups.")
    when :saved then success(automation_saved(result))
    else return render_rejected
    end
    render json: answer(outcome: outcome)
  end

  def back_up_item
    item_id = params[:item_id].to_s
    raise ActiveRecord::RecordNotFound unless item_id.match?(IDENTIFIER)

    separate_edition = body.fetch("separate_edition", false)
    raise Malformed, "Send separate edition as true or false" unless SWITCH_VALUES.include?(separate_edition)

    result = workflow.back_up_item(item_id: item_id, separate_edition: separate_edition)
    render json: answer(outcome: item_outcome(result), item: item_id)
  rescue ActiveRecord::RecordInvalid => e
    render json: answer(outcome: failure(e.record.errors.full_messages.to_sentence), item: item_id)
  rescue ActiveRecord::RecordNotUnique
    render json: answer(outcome: failure("A backup is already active for this title."), item: item_id)
  end

  private

  def connection
    @connection ||= OwnedLibraryConnectionWorkflow.default_connection
  end

  def workflow
    @workflow ||= OwnedLibraryConnectionWorkflow.new(connection, user: Current.user)
  end

  def presenter
    @presenter ||= WebPreview::AudibleBackupJson.new(workflow, user: Current.user)
  end

  def answer(auth_pending: false, **extra)
    { account: web_preview_account_id, **presenter.state(workflow.summary(auth_pending: auth_pending, quiet_during_backlog: true)), **extra }
  end

  def body
    request.request_parameters
  end

  def require_acting_administrator
    raise Forbidden unless User.active.admin.exists?(id: Current.user.id)
  end

  def require_saved_connection
    raise ActiveRecord::RecordNotFound unless connection.persisted?
  end

  def submitted_connection
    raw = body["companion"]
    raise Malformed, "Send the companion as an object of names and values" unless raw.is_a?(Hash)

    values = raw.slice(*TEXTS, *SWITCHES, "timeout_seconds")
    wrong = TEXTS.select { |key| values.key?(key) && !values[key].is_a?(String) } +
      SWITCHES.select { |key| values.key?(key) && !SWITCH_VALUES.include?(values[key]) }
    wrong << "timeout_seconds" if values.key?("timeout_seconds") && !values["timeout_seconds"].is_a?(Integer) && !values["timeout_seconds"].is_a?(String)
    raise Malformed, "These values have the wrong type: #{wrong.join(', ')}" if wrong.any?

    values
  end

  def submitted_automation
    raw = body["automation"]
    raise Malformed, "Send automation as an object of names and values" unless raw.is_a?(Hash)

    values = raw.slice(*OwnedLibraryConnectionWorkflow::AUTOMATION_ATTRIBUTES.map(&:to_s))
    switches = %w[scheduled_sync_enabled automatic_backup_enabled]
    wrong = switches.reject { |key| SWITCH_VALUES.include?(values[key]) }
    wrong << "scheduled_sync_interval_minutes" unless values["scheduled_sync_interval_minutes"].is_a?(Integer)
    raise Malformed, "These values have the wrong type: #{wrong.join(', ')}" if wrong.any?

    values
  end

  def render_rejected
    errors = connection.errors.map { |error| { field: error.attribute.to_s, message: field_message(error) } }
    render json: { account: web_preview_account_id, error: "invalid_record", errors: errors }, status: :unprocessable_entity
  end

  def field_message(error)
    label = FIELD_LABELS[error.attribute.to_s]
    presenter.redact(label ? "#{label} #{error.message}" : error.full_message)
  end

  def automation_saved(result)
    return "Audible automation turned off. Manual sync and backup stay available." unless result.scheduled_sync_enabled
    return "Scheduled Audible library sync turned on. Automatic backups stay off." unless result.automatic_backup_enabled

    "Audible automation saved. The next successful sync refreshes the no-download baseline; later purchases can be backed up automatically."
  end

  def item_outcome(result)
    title = result.item&.display_title
    case result.status
    when :storage_not_ready then failure(workflow.storage_error)
    when :disabled then failure("Turn on Audible backup before backing up a title.")
    when :auth_active then failure("Finish the current Audible sign-in before queueing backups.")
    when :sync_active then failure("Wait for the Audible library sync to finish before queueing backups.")
    when :not_purchased then failure("Only titles confirmed as purchased can be backed up.")
    when :already_in_library then success("This title is already in the Shelfarr library. Its existing file was kept.")
    when :local_conflict then failure("A local audiobook has the same title, but Shelfarr could not confirm it is the same edition. Choose Back up separately to keep both.")
    when :already_active then success("This Audible backup is already queued or running.")
    when :enqueue_failed then failure("Shelfarr could not queue the Libation backup. Try again.")
    when :resume then success("Backup status check for “#{title}” queued.")
    when :queued then success("Backup of “#{title}” queued through Libation.")
    else failure("This title could not be backed up.")
    end
  end
end
