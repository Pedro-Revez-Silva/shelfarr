# frozen_string_literal: true

class WebPreview::Admin::SettingsController < WebPreview::Admin::BaseController
  PRIVATE_ADDRESS_PROBES = %w[webhook discord].freeze
  PRIVATE_ADDRESS_FAILURE = { tone: "error", message: "The test message was not delivered. Check that sending is turned on, the address and token are right, and the receiving service is reachable. The service's reply is not shown because it can contain the address." }.freeze

  rescue_from WebPreview::AdminSettings::Unknown, with: ->(error) { render_error("invalid_request", :bad_request, message: error.message) }

  def show
    render json: { account: web_preview_account_id, **presenter.representation }
  end

  def update
    result = presenter.save(params[:group], submitted_values)
    if result.rejected?
      render json: { account: web_preview_account_id, error: "invalid_settings", errors: result.rejections.map { |rejection| { key: rejection.key, message: rejection.text } } },
        status: :unprocessable_entity
      return
    end

    outcome = if result.follow_up_error
      failure("Settings saved, but a follow-up action failed: #{result.follow_up_error.message}")
    else
      success(result.changed_keys.any? ? "Settings saved." : "There were no changes to save.")
    end
    render json: { account: web_preview_account_id, outcome: outcome, changed: result.changed_keys, group: presenter.group_json(params[:group]) }
  rescue ArgumentError => error
    render json: { account: web_preview_account_id, error: "invalid_settings", errors: [ { key: nil, message: WebPreview::SecretRedaction.call(error.message) } ] }, status: :unprocessable_entity
  end

  def probe
    name = params[:probe].to_s
    raise WebPreview::AdminSettings::Unknown, "Unknown connection check" unless ServerSettings::Probe::NAMES.include?(name)

    outcome = ServerSettings::Probe.new(posted: probe_values, telegram_webhook_url: integrations_telegram_webhook_url).call(name)
    render json: { account: web_preview_account_id, outcome: private_address_probe?(name, outcome) ? PRIVATE_ADDRESS_FAILURE : outcome_json(outcome) }
  end

  private

  def private_address_probe?(name, outcome)
    PRIVATE_ADDRESS_PROBES.include?(name) && !outcome.success?
  end

  def presenter
    @presenter ||= WebPreview::AdminSettings.new(base_url: request.base_url)
  end

  def submitted_values
    values = params[:values]
    return values.to_unsafe_h if values.is_a?(ActionController::Parameters)

    raise WebPreview::AdminSettings::Unknown, "Send the settings as an object of names and values"
  end

  def probe_values
    values = params[:values]
    values.is_a?(ActionController::Parameters) ? values.to_unsafe_h.slice(*ServerSettings::Probe::POSTED_KEYS) : {}
  end
end
