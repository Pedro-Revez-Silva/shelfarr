# frozen_string_literal: true

class WebPreview::BootstrapController < WebPreview::APIController
  CSRF_LIFETIME = 2.hours
  OFFLINE_WINDOW_LIMIT = 30.days
  SIGN_IN = { available: false, reason: "rails_sign_in" }.freeze

  def show
    render json: { authenticated: true, account: web_preview_account_id, csrf_token: form_authenticity_token,
      expires_in: CSRF_LIFETIME.to_i, offline_expires_in: offline_window, offline_continuity: offline_continuity }
  end

  private

  def web_preview_verify_account
  end

  def web_preview_signed_out
    private_response
    render json: { authenticated: false, csrf_token: form_authenticity_token, expires_in: CSRF_LIFETIME.to_i, sign_in: SIGN_IN }
  end

  def offline_window
    now = Time.current
    ends = [ Current.session.created_at + SettingsService.get(:session_max_age_days, default: 30).to_i.days, now + OFFLINE_WINDOW_LIMIT ]
    ends << signed_cookie_expiry if signed_cookie_expiry
    (ends.min - now).clamp(0, OFFLINE_WINDOW_LIMIT.to_i).to_i
  end

  def signed_cookie_expiry
    return @signed_cookie_expiry if defined?(@signed_cookie_expiry)

    @signed_cookie_expiry = read_signed_cookie_expiry
  end

  def read_signed_cookie_expiry
    envelope = JSON.parse(Base64.strict_decode64(cookies[:session_id].to_s.split("--").first.to_s))
    expiry = envelope.is_a?(Hash) ? envelope.dig("_rails", "exp") : nil
    expiry.nil? ? nil : Time.iso8601(expiry)
  rescue ArgumentError, JSON::ParserError, TypeError
    Time.current
  end
end
