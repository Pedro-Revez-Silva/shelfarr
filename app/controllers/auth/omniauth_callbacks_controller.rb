# frozen_string_literal: true

module Auth
  class OmniauthCallbacksController < ApplicationController
    allow_unauthenticated_access only: %i[oidc failure]

    def oidc
      auth_hash = request.env["omniauth.auth"]

      unless auth_hash
        redirect_to oidc_failure_redirect_path, alert: "Authentication failed: No data received from provider"
        return
      end

      if oidc_link_in_progress?
        complete_oidc_link(auth_hash)
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
      redirect_to oidc_failure_redirect_path, alert: "SSO authentication failed: #{message}"
    end

    private

    def oidc_link_in_progress?
      session[:pending_oidc_link_user_id].present?
    end

    def complete_oidc_login(user, auth_hash)
      # Check if account is locked
      if user.locked?
        log_security_event("oidc_login.blocked_locked", user)
        redirect_to oidc_failure_redirect_path, alert: "Account is locked. Try again in #{user.unlock_in_words}."
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

    def complete_oidc_link(auth_hash)
      user = User.active.find_by(id: session.delete(:pending_oidc_link_user_id))

      unless user
        redirect_to oidc_failure_redirect_path, alert: "OIDC link session expired. Sign in locally and try again."
        return
      end

      user.link_oidc_identity!(provider: auth_hash["provider"], uid: auth_hash["uid"])

      ActivityTracker.track("user.oidc_linked", user: user)
      log_security_event("oidc_link.success", user)

      provider_name = SettingsService.get(:oidc_provider_name, default: "SSO")
      redirect_to profile_path, notice: "#{provider_name} is now linked to your account."
    rescue User::OidcIdentityAlreadyLinkedError
      redirect_to profile_path, alert: "That OIDC account is already linked to another Shelfarr user."
    rescue User::OidcIdentityConflictError
      redirect_to profile_path, alert: "This Shelfarr account is already linked to a different OIDC identity."
    end

    def handle_oidc_failure(message)
      redirect_to oidc_failure_redirect_path, alert: message
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

    def oidc_failure_redirect_path
      if oidc_link_in_progress?
        session.delete(:pending_oidc_link_user_id)
        return profile_path
      end

      SettingsService.oidc_auto_redirect? ? new_session_path(local: 1) : new_session_path
    end
  end
end
