# frozen_string_literal: true

module Auth
  class OmniauthCallbacksController < ApplicationController
    allow_unauthenticated_access only: %i[oidc failure]
    protect_from_forgery except: :oidc

    def oidc
      auth_hash = request.env["omniauth.auth"]

      unless auth_hash
        redirect_to new_session_path, alert: "Authentication failed: No data received from provider"
        return
      end

      user = User.from_oidc(auth_hash)

      if user
        complete_oidc_login(user, auth_hash)
      else
        handle_oidc_failure("User not found. Contact an administrator to create your account or enable auto-registration.")
      end
    rescue StandardError => e
      Rails.logger.error "[OIDC] Authentication error: #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n")
      handle_oidc_failure("Authentication error: #{e.message}")
    end

    def failure
      message = params[:message] || "Unknown error"
      Rails.logger.warn "[OIDC] Authentication failed: #{message}"
      redirect_to new_session_path, alert: "SSO authentication failed: #{message}"
    end

    private

    def complete_oidc_login(user, auth_hash)
      # Check if account is locked
      if user.locked?
        log_security_event("oidc_login.blocked_locked", user)
        redirect_to new_session_path, alert: "Account is locked. Try again in #{user.unlock_in_words}."
        return
      end

      # OIDC users skip 2FA (they're already authenticated via SSO)
      user.reset_failed_logins!
      start_new_session_for(user)

      ActivityTracker.track("user.oidc_login", user: user)
      log_security_event("oidc_login.success", user)

      provider_name = SettingsService.get(:oidc_provider_name, default: "SSO")
      redirect_to after_authentication_url, notice: "Signed in via #{provider_name}"
    end

    def handle_oidc_failure(message)
      redirect_to new_session_path, alert: message
    end

    def log_security_event(event_type, user = nil)
      details = {
        event: event_type,
        ip: request.remote_ip,
        user_agent: request.user_agent,
        timestamp: Time.current.iso8601
      }
      details[:user_id] = user.id if user
      details[:username] = user&.username

      Rails.logger.info "[Security] #{event_type}: #{details.to_json}"
    end
  end
end
