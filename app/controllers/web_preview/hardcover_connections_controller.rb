# frozen_string_literal: true

class WebPreview::HardcoverConnectionsController < WebPreview::APIController
  DISCONNECTED = "Hardcover account disconnected. Requests already created were kept."
  CHANGED = "Your Hardcover connection changed after this page was shown. Review it and try again."
  DISABLED = "Hardcover is disabled on this Shelfarr instance."
  SIGN_IN_OFF = "Hardcover sign-in is not configured. An administrator can add a Hardcover OAuth client in Settings."
  CODE_OFF = "Sign-in with a code is not enabled on this Shelfarr instance."
  API_KEY_OFF = "Personal API keys are not enabled on this Shelfarr instance."
  INSECURE_REDIRECT = "Hardcover only accepts HTTPS redirect addresses (or localhost). Use sign-in with a code, or ask an administrator to set the redirect URI."

  before_action :hide_referrer
  before_action :require_enabled, except: :show
  rescue_from ActionDispatch::Http::Parameters::ParseError, with: -> { render_error("invalid_request", :bad_request) }

  def show
    render_state(outcome: sign_in.take_outcome)
  end

  def create
    return unavailable(API_KEY_OFF) unless HardcoverIntegration.personal_tokens_allowed?

    generation = Hardcover::ConnectionManager.sign_in_generation(Current.user)
    return unless expected_connection?

    raw = request.request_parameters["api_key"]
    return render_error("invalid_request", :bad_request) unless raw.is_a?(String)

    api_key = Hardcover::PersonalSignIn.api_key(raw)
    return refuse("invalid_api_key", "Paste a Hardcover API key to connect.", :unprocessable_entity) unless api_key

    connection = sign_in.connect_api_key(api_key, generation: generation)
    render_state(notice: "Connected Hardcover account @#{connection.hardcover_username}.")
  rescue Hardcover::ConnectionManager::ConnectionChanged
    refuse("hardcover_changed", CHANGED, :conflict)
  rescue HardcoverClient::Error => e
    refuse("hardcover_refused", Hardcover::PersonalSignIn.error_message(e), :unprocessable_entity)
  end

  def authorize
    return unavailable(SIGN_IN_OFF) unless HardcoverIntegration.oauth_configured?

    generation = Hardcover::ConnectionManager.sign_in_generation(Current.user)
    return unless expected_connection?

    url = sign_in.start_oauth(request.base_url, warm: true, generation: generation)
    return unavailable(INSECURE_REDIRECT) unless url

    render json: { account: web_preview_account_id, authorization_url: url }
  end

  def device
    return unavailable(CODE_OFF) unless HardcoverIntegration.device_flow_enabled?

    generation = Hardcover::ConnectionManager.sign_in_generation(Current.user)
    return unless expected_connection?

    sign_in.start_device(generation: generation)
    render_state
  rescue Hardcover::Oauth::Error => e
    refuse("hardcover_refused", Hardcover::PersonalSignIn.error_message(e), :unprocessable_entity)
  end

  def device_poll
    return unavailable(CODE_OFF) unless HardcoverIntegration.device_flow_enabled?

    poll = sign_in.poll_device
    notice = "Connected Hardcover account @#{poll.connection.hardcover_username}." if poll.status == :approved
    render json: { account: web_preview_account_id, status: poll.status, message: poll.message || notice, hardcover: state }.compact
  end

  def cancel_device
    sign_in.forget_device
    Hardcover::ConnectionManager.end_sign_ins!(Current.user)
    render_state
  end

  def disconnect
    version = request.request_parameters["version"]
    return render_error("invalid_request", :bad_request) unless version.is_a?(String)

    connection = current_connection
    return render_state(notice: "No Hardcover account is connected.") unless connection
    return refuse("hardcover_changed", CHANGED, :conflict) unless Hardcover::ConnectionManager.disconnect!(connection, expected_version: version)

    sign_in.forget_sign_ins
    render_state(notice: DISCONNECTED)
  end

  private

  def sign_in
    @sign_in ||= Hardcover::PersonalSignIn.new(session: session, user: Current.user)
  end

  def current_connection
    HardcoverConnection.find_by(user_id: Current.user.id)
  end

  def hide_referrer
    headers["Referrer-Policy"] = "no-referrer"
  end

  def require_enabled
    unavailable(DISABLED) unless HardcoverIntegration.enabled?
  end

  def expected_connection?
    body = request.request_parameters
    expected = body["version"]
    unless body.key?("version") && (expected.nil? || expected.is_a?(String))
      render_error("invalid_request", :bad_request)
      return false
    end
    return true if expected == current_connection&.version

    refuse("hardcover_changed", CHANGED, :conflict)
    false
  end

  def state(outcome: nil)
    WebPreview::HardcoverConnectionJson.new(Current.user, sign_in: sign_in, routes: self).state(outcome: outcome)
  end

  def render_state(notice: nil, outcome: nil)
    render json: { account: web_preview_account_id, hardcover: state(outcome: outcome), notice: notice }.compact
  end

  def unavailable(message)
    refuse("hardcover_unavailable", message, :conflict)
  end

  def refuse(code, message, status)
    render json: { account: web_preview_account_id, error: code, message: message, hardcover: state }, status: status
  end
end
