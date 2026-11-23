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

    before_action :open_warm_page, only: :show_device

    def create
      unless HardcoverIntegration.personal_tokens_allowed?
        redirect_to profile_path, alert: "Personal API keys are not enabled on this Shelfarr instance."
        return
      end

      api_key = PersonalSignIn.api_key(params[:api_key].to_s)
      unless api_key
        redirect_to profile_path, alert: "Paste a Hardcover API key to connect."
        return
      end

      connection = sign_in.connect_api_key(api_key)
      redirect_to hardcover_subscriptions_path, notice: "Connected Hardcover account @#{connection.hardcover_username}."
    rescue HardcoverClient::Error => e
      redirect_to profile_path, alert: PersonalSignIn.error_message(e)
    end

    def authorize
      url = sign_in.start_oauth(request.base_url)
      unless url
        redirect_to profile_path, alert: "Hardcover only accepts HTTPS redirect addresses (or localhost). Use sign-in with a code, or ask an administrator to set the redirect URI."
        return
      end

      redirect_to url, allow_other_host: true
    end

    def callback
      pending = sign_in.take_oauth(params[:state])
      return refuse("That Hardcover sign-in expired or was started elsewhere. Please try again.") unless pending

      if params[:error].present?
        return refuse(params[:error] == "access_denied" ? "Hardcover sign-in was cancelled." : "Hardcover sign-in failed.")
      end
      return refuse("Hardcover sign-in failed: the response did not come from Hardcover.") unless Oauth.valid_issuer?(params[:iss])
      return refuse("Hardcover sign-in failed: no authorization code was returned.") if params[:code].blank?

      connected(sign_in.finish_oauth(pending, params[:code].to_s))
    rescue Oauth::Error, HardcoverClient::Error => e
      refuse(PersonalSignIn.error_message(e))
    end

    def device
      sign_in.start_device
      redirect_to device_hardcover_connection_path
    rescue Oauth::Error => e
      redirect_to profile_path, alert: PersonalSignIn.error_message(e)
    end

    def show_device
      @device = sign_in.pending_device
      redirect_to profile_path, alert: "Start Hardcover sign-in again." unless @device
    end

    def device_poll
      poll = sign_in.poll_device
      flash[:notice] = "Connected Hardcover account @#{poll.connection.hardcover_username}." if poll.status == :approved
      device_poll_response(poll.status, poll.message)
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

    def sign_in
      @sign_in ||= PersonalSignIn.new(session: session, user: Current.user)
    end

    def require_hardcover
      return if HardcoverIntegration.enabled?

      refuse("Hardcover is disabled on this Shelfarr instance.")
    end

    def require_oauth
      return if HardcoverIntegration.oauth_configured?

      refuse("Hardcover sign-in is not configured. An administrator can add a Hardcover OAuth client in Settings.")
    end

    def require_device_flow
      return if HardcoverIntegration.device_flow_enabled?

      redirect_to profile_path, alert: "Sign-in with a code is not enabled on this Shelfarr instance."
    end

    def warm_callback?
      action_name == "callback" && PersonalSignIn.warm_state?(params[:state]) && WebPreview::Access.current.allows?(Current.user)
    end

    def refuse(message)
      return redirect_to(profile_path, alert: message) unless warm_callback?

      return_to_warm_page("error", message)
    end

    def connected(connection)
      message = "Connected Hardcover account @#{connection.hardcover_username}."
      return redirect_to(hardcover_subscriptions_path, notice: message) unless warm_callback?

      return_to_warm_page("success", message)
    end

    def return_to_warm_page(tone, message)
      sign_in.remember_outcome(tone, message)
      response.headers["Cache-Control"] = "private, no-store"
      response.headers["Referrer-Policy"] = "no-referrer"
      redirect_to web_preview_account_section_path(section: "connections", anchor: "hardcover"), status: :see_other
    end

    def open_warm_page
      return unless flash.empty? && WebPreview::Access.current.allows?(Current.user) && WarmEntry.stylesheet_built?

      redirect_to web_preview_account_section_path(section: "connections", anchor: "hardcover")
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
  end
end
