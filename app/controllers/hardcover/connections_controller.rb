# frozen_string_literal: true

module Hardcover
  # Connects the signed-in user's own Hardcover account.
  #
  # OAuth uses the authorization code flow with PKCE (S256), a single-use
  # state bound to this user's session, and an issuer check on the callback.
  # Tokens never reach the browser.
  class ConnectionsController < ApplicationController
    before_action :require_hardcover
    before_action :require_oauth, only: [ :authorize, :callback ]
    before_action :require_device_flow, only: [ :device, :device_poll ]

    OAUTH_SESSION_KEY = :hardcover_oauth
    DEVICE_SESSION_KEY = :hardcover_device

    def create
      unless HardcoverIntegration.personal_tokens_allowed?
        redirect_to profile_path, alert: "Personal API keys are not enabled on this Shelfarr instance."
        return
      end

      api_key = params[:api_key].to_s.strip.sub(/\ABearer\s+/i, "")
      if api_key.blank? || api_key.length > 2_000
        redirect_to profile_path, alert: "Paste a Hardcover API key to connect."
        return
      end

      connection = ConnectionManager.connect!(user: Current.user, auth_method: "personal_token", access_token: api_key)
      redirect_to hardcover_subscriptions_path, notice: "Connected Hardcover account @#{connection.hardcover_username}."
    rescue HardcoverClient::Error => e
      redirect_to profile_path, alert: connection_error_message(e)
    end

    def authorize
      redirect_uri = HardcoverIntegration.redirect_uri(request.base_url)
      unless HardcoverIntegration.redirect_uri_acceptable?(redirect_uri)
        redirect_to profile_path, alert: "Hardcover only accepts HTTPS redirect addresses (or localhost). Use sign-in with a code, or ask an administrator to set the redirect URI."
        return
      end

      state = SecureRandom.urlsafe_base64(32)
      verifier, challenge = Oauth.generate_pkce
      session[OAUTH_SESSION_KEY] = {
        "state" => state,
        "verifier" => verifier,
        "redirect_uri" => redirect_uri,
        "user_id" => Current.user.id,
        "expires_at" => Oauth::PENDING_TTL.from_now.to_i
      }
      redirect_to Oauth.authorization_url(state: state, code_challenge: challenge, redirect_uri: redirect_uri), allow_other_host: true
    end

    def callback
      pending = session.delete(OAUTH_SESSION_KEY)
      unless valid_pending_oauth?(pending)
        redirect_to profile_path, alert: "That Hardcover sign-in expired or was started elsewhere. Please try again."
        return
      end

      if params[:error].present?
        message = params[:error] == "access_denied" ? "Hardcover sign-in was cancelled." : "Hardcover sign-in failed."
        redirect_to profile_path, alert: message
        return
      end

      unless Oauth.valid_issuer?(params[:iss])
        redirect_to profile_path, alert: "Hardcover sign-in failed: the response did not come from Hardcover."
        return
      end

      if params[:code].blank?
        redirect_to profile_path, alert: "Hardcover sign-in failed: no authorization code was returned."
        return
      end

      token_set = Oauth.exchange_code(code: params[:code].to_s, code_verifier: pending["verifier"], redirect_uri: pending["redirect_uri"])
      connect_oauth!(token_set)
    rescue Oauth::Error, HardcoverClient::Error => e
      redirect_to profile_path, alert: connection_error_message(e)
    end

    def device
      authorization = Oauth.start_device_authorization
      session[DEVICE_SESSION_KEY] = {
        "device_code" => authorization.device_code,
        "user_code" => authorization.user_code,
        "verification_uri" => authorization.verification_uri,
        "verification_uri_complete" => authorization.verification_uri_complete,
        "interval" => authorization.interval,
        "expires_at" => authorization.expires_at.to_i,
        "next_poll_at" => (Time.current + authorization.interval).to_i,
        "user_id" => Current.user.id
      }
      redirect_to device_hardcover_connection_path
    rescue Oauth::Error => e
      redirect_to profile_path, alert: connection_error_message(e)
    end

    def show_device
      @device = pending_device
      redirect_to profile_path, alert: "Start Hardcover sign-in again." unless @device
    end

    # Polled by the device page. Hardcover sets the polling interval; this
    # endpoint enforces it server-side so a busy browser cannot exceed it.
    def device_poll
      pending = pending_device
      return device_poll_response(:failed, "Hardcover sign-in expired. Start again.") unless pending
      return device_poll_response(:pending) if Time.current.to_i < pending["next_poll_at"].to_i

      poll = Oauth.poll_device_authorization(pending["device_code"])
      case poll.status
      when :approved
        session.delete(DEVICE_SESSION_KEY)
        connection = ConnectionManager.connect!(
          user: Current.user,
          auth_method: "oauth",
          access_token: poll.token_set.access_token,
          refresh_token: poll.token_set.refresh_token,
          expires_at: poll.token_set.expires_at,
          scope: poll.token_set.scope
        )
        flash[:notice] = "Connected Hardcover account @#{connection.hardcover_username}."
        device_poll_response(:approved)
      when :pending, :slow_down
        interval = pending["interval"].to_i + poll.interval.to_i
        session[DEVICE_SESSION_KEY] = pending.merge("interval" => interval, "next_poll_at" => (Time.current + interval).to_i)
        device_poll_response(:pending)
      else
        session.delete(DEVICE_SESSION_KEY)
        device_poll_response(:failed, poll.status == :denied ? "Hardcover sign-in was declined." : "The sign-in code expired. Start again.")
      end
    rescue Oauth::Error, HardcoverClient::Error => e
      session.delete(DEVICE_SESSION_KEY)
      device_poll_response(:failed, connection_error_message(e))
    end

    def destroy
      connection = Current.user.hardcover_connection
      if connection
        ConnectionManager.disconnect!(connection)
        redirect_to profile_path, notice: "Hardcover account disconnected. Requests already created were kept.", status: :see_other
      else
        redirect_to profile_path, status: :see_other
      end
    end

    private

    def require_hardcover
      return if HardcoverIntegration.enabled?

      redirect_to profile_path, alert: "Hardcover is disabled on this Shelfarr instance."
    end

    def require_oauth
      return if HardcoverIntegration.oauth_configured?

      redirect_to profile_path, alert: "Hardcover sign-in is not configured. An administrator can add a Hardcover OAuth client in Settings."
    end

    def require_device_flow
      return if HardcoverIntegration.device_flow_enabled?

      redirect_to profile_path, alert: "Sign-in with a code is not enabled on this Shelfarr instance."
    end

    def valid_pending_oauth?(pending)
      return false unless pending.is_a?(Hash)
      return false unless pending["user_id"] == Current.user.id
      return false if pending["expires_at"].to_i < Time.current.to_i

      ActiveSupport::SecurityUtils.secure_compare(pending["state"].to_s, params[:state].to_s)
    end

    def pending_device
      pending = session[DEVICE_SESSION_KEY]
      return unless pending.is_a?(Hash) && pending["user_id"] == Current.user.id
      return if pending["expires_at"].to_i < Time.current.to_i

      pending
    end

    def connect_oauth!(token_set)
      connection = ConnectionManager.connect!(
        user: Current.user,
        auth_method: "oauth",
        access_token: token_set.access_token,
        refresh_token: token_set.refresh_token,
        expires_at: token_set.expires_at,
        scope: token_set.scope
      )
      redirect_to hardcover_subscriptions_path, notice: "Connected Hardcover account @#{connection.hardcover_username}."
    end

    def device_poll_response(status, message = nil)
      respond_to do |format|
        format.json do
          payload = { status: status }
          payload[:message] = message if message
          payload[:redirect_url] = hardcover_subscriptions_path if status == :approved
          payload[:redirect_url] = profile_path if status == :failed
          render json: payload
        end
        format.html do
          case status
          when :approved then redirect_to hardcover_subscriptions_path
          when :failed then redirect_to profile_path, alert: message
          else redirect_to device_hardcover_connection_path, notice: "Waiting for approval on Hardcover."
          end
        end
      end
    end

    def connection_error_message(error)
      case error
      when HardcoverClient::ScopeError
        "#{error.message}. Create the key with the read:me:content, read:library, read:lists, and read:catalog permissions."
      when HardcoverClient::AuthenticationError
        "Hardcover rejected that key. Check that it is current and has not been revoked."
      when HardcoverClient::RateLimitError
        "Hardcover's rate limit was reached. Try again in a few minutes."
      when Oauth::AuthorizationError
        "Hardcover did not accept the sign-in (#{error.message}). Check the client ID, secret, and registered redirect URI."
      else
        "Could not connect to Hardcover: #{error.message}"
      end
    end
  end
end
