# frozen_string_literal: true

class WebPreview::AccountSecurityController < WebPreview::APIController
  IDENTIFIER = /\A[1-9]\d{0,18}\z/
  NAME_LIMIT = 100

  def setup_two_factor
    user = Current.user
    return render_error("two_factor_enabled", :conflict) if user.otp_enabled?

    user.generate_otp_secret! if user.otp_secret.blank?
    uri = user.otp_provisioning_uri
    render json: { account: web_preview_account_id, setup: { secret: user.otp_secret, uri: uri, qr_svg: qr_svg(uri) } }
  end

  def enable_two_factor
    user = Current.user
    return render_error("two_factor_enabled", :conflict) if user.otp_enabled?
    return render_error("two_factor_not_started", :conflict) if user.otp_secret.blank?
    return render_error("invalid_code", :unprocessable_entity) unless params[:otp_code].is_a?(String) && user.verify_otp(params[:otp_code].strip)

    render_codes(user.enable_otp!)
  end

  def disable_two_factor
    user = Current.user
    return render_error("two_factor_disabled", :conflict) unless user.otp_enabled?
    return render_error("invalid_password", :unprocessable_entity) unless password_confirmed?(user)

    user.disable_otp!
    render_account
  end

  def backup_codes
    user = Current.user
    return render_error("two_factor_disabled", :conflict) unless user.otp_enabled?
    return render_error("invalid_password", :unprocessable_entity) unless password_confirmed?(user)

    render_codes(user.generate_backup_codes!)
  end

  def create_api_token
    user = Current.user
    scopes = requested_scopes(user)
    return render_error("invalid_scopes", :unprocessable_entity) unless scopes

    name = params[:name].is_a?(String) ? params[:name].strip.first(NAME_LIMIT).presence : nil
    token, raw_token = APIToken.issue!(name: name || "API token", user: user, scopes: scopes)
    ActivityTracker.track("user.api_token_created", user: user, details: { api_token_id: token.id, scopes: token.scope_list })
    render json: { account: web_preview_account_id, token: account_json.token(token), secret: raw_token }, status: :created
  rescue ActiveRecord::RecordInvalid => error
    render_error("invalid_token", :unprocessable_entity, message: error.record.errors.full_messages.to_sentence.first(300))
  end

  def revoke_api_token
    raise ActiveRecord::RecordNotFound unless params[:id].is_a?(String) && params[:id].match?(IDENTIFIER)

    user = Current.user
    token = user.api_tokens.find(params[:id])
    token.revoke!
    ActivityTracker.track("user.api_token_revoked", user: user, details: { api_token_id: token.id })
    render_account
  end

  def unlink_oidc
    user = Current.user
    return render_error("oidc_not_linked", :conflict) unless user.oidc_user?
    return render_error("invalid_password", :unprocessable_entity) unless SettingsService.auth_disabled? || password_confirmed?(user, :current_password)

    user.unlink_oidc_identity!
    session.delete(:pending_oidc_link_user_id)
    ActivityTracker.track("user.oidc_unlinked", user: user)
    render_account
  end

  private

  def password_confirmed?(user, field = :password)
    params[field].is_a?(String) && user.authenticate(params[field]).present?
  end

  def requested_scopes(user)
    raw = params[:scopes]
    return unless raw.nil? || raw.is_a?(String) || (raw.is_a?(Array) && raw.all?(String))

    requested = APIToken.normalize_scopes(raw.nil? ? APIToken::SELF_SERVICE_SCOPES : raw)
    allowed = user.admin? ? APIToken::AVAILABLE_SCOPES : APIToken::SELF_SERVICE_SCOPES
    requested if requested.any? && (requested - allowed).empty?
  end

  def render_codes(codes)
    render json: { account: web_preview_account_id, backup_codes: codes }
  end

  def render_account
    render json: { account: web_preview_account_id, profile: account_json.profile }
  end

  def account_json
    WebPreview::AccountJson.new(Current.user, routes: self)
  end

  def qr_svg(uri)
    return unless uri

    RQRCode::QRCode.new(uri).as_svg(offset: 0, color: "000", shape_rendering: "crispEdges", module_size: 4, standalone: true, use_path: true)
  end
end
