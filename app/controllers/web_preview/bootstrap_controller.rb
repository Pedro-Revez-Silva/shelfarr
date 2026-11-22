# frozen_string_literal: true

class WebPreview::BootstrapController < WebPreview::APIController
  CSRF_LIFETIME = 2.hours
  OFFLINE_WINDOW_LIMIT = 30.days
  SIGN_IN = { available: false, reason: "rails_sign_in" }.freeze

  def show
    render json: { authenticated: true, account: web_preview_account_id, csrf_token: form_authenticity_token,
      expires_in: CSRF_LIFETIME.to_i, offline_expires_in: offline_window }
  end

  private

  def web_preview_verify_account
  end

  def web_preview_signed_out
    private_response
    render json: { authenticated: false, csrf_token: form_authenticity_token, expires_in: CSRF_LIFETIME.to_i, sign_in: SIGN_IN }
  end

  def offline_window
    ends = Current.session.created_at + SettingsService.get(:session_max_age_days, default: 30).to_i.days
    (ends - Time.current).clamp(0, OFFLINE_WINDOW_LIMIT.to_i).to_i
  end
end
