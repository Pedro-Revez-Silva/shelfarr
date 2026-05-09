# frozen_string_literal: true

class ProfilesController < ApplicationController
  def show
    @user = Current.user
    @api_tokens = @user.api_tokens.order(created_at: :desc)
    @stats = {
      total_requests: @user.requests.count,
      completed_requests: @user.requests.completed.count,
      pending_requests: @user.requests.pending.count
    }
  end

  def edit
    @user = Current.user
  end

  def update
    @user = Current.user
    if @user.update(profile_params)
      redirect_to profile_path, notice: "Profile updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def password
    @user = Current.user
  end

  def update_password
    @user = Current.user

    unless @user.authenticate(params[:current_password])
      @user.errors.add(:current_password, "is incorrect")
      return render :password, status: :unprocessable_entity
    end

    if @user.update(password_params)
      @user.sessions.where.not(id: Current.session.id).destroy_all
      redirect_to profile_path, notice: "Password changed successfully."
    else
      render :password, status: :unprocessable_entity
    end
  end

  def link_oidc
    @user = Current.user

    unless SettingsService.oidc_configured?
      redirect_to profile_path, alert: "OIDC must be fully configured before you can link an account."
      return
    end

    if @user.oidc_user?
      redirect_to profile_path, notice: "Your account is already linked to OIDC."
      return
    end

    session[:pending_oidc_link_user_id] = @user.id
    render :link_oidc_redirect
  end

  def unlink_oidc
    @user = Current.user

    unless @user.oidc_user?
      redirect_to profile_path, notice: "Your account is not linked to OIDC."
      return
    end

    unless SettingsService.auth_disabled? || @user.authenticate(params[:current_password])
      redirect_to profile_path, alert: "Current password is incorrect."
      return
    end

    @user.unlink_oidc_identity!
    session.delete(:pending_oidc_link_user_id)

    ActivityTracker.track("user.oidc_unlinked", user: @user)
    redirect_to profile_path, notice: "OIDC sign-in has been removed from your account."
  end

  def generate_telegram_link_code
    @user = Current.user

    unless SettingsService.get(:telegram_enabled, default: false)
      redirect_to profile_path, alert: "Telegram must be enabled before you can link an account."
      return
    end

    code = @user.generate_telegram_link_code!
    ActivityTracker.track("user.telegram_link_code_generated", user: @user)
    redirect_to profile_path, notice: "Telegram link code: #{code}. Send /link #{@user.username} #{code} to the Shelfarr bot within 15 minutes."
  end

  def unlink_telegram
    @user = Current.user

    unless @user.telegram_linked?
      redirect_to profile_path, notice: "Your account is not linked to Telegram."
      return
    end

    @user.unlink_telegram_identity!
    ActivityTracker.track("user.telegram_unlinked", user: @user)
    redirect_to profile_path, notice: "Telegram has been removed from your account."
  end

  def create_api_token
    @user = Current.user
    scopes = params[:scopes].presence || %w[search:read requests:read requests:write]
    token, raw_token = APIToken.issue!(
      name: params[:name].presence || "API token",
      user: @user,
      scopes: scopes
    )

    ActivityTracker.track("user.api_token_created", user: @user, details: { api_token_id: token.id, scopes: token.scope_list })
    redirect_to profile_path, notice: "API token created: #{raw_token}. Copy it now; Shelfarr will not show it again."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to profile_path, alert: e.record.errors.full_messages.to_sentence
  end

  def revoke_api_token
    @user = Current.user
    token = @user.api_tokens.find(params[:id])
    token.revoke!

    ActivityTracker.track("user.api_token_revoked", user: @user, details: { api_token_id: token.id })
    redirect_to profile_path, notice: "API token revoked."
  end

  # Two-factor authentication setup
  def two_factor
    @user = Current.user

    # Generate a new secret if not already set up
    unless @user.otp_enabled?
      @user.generate_otp_secret! unless @user.otp_secret.present?
      @provisioning_uri = @user.otp_provisioning_uri
      @qr_code = generate_qr_code(@provisioning_uri)
    end
  end

  def enable_two_factor
    @user = Current.user

    unless @user.otp_secret.present?
      redirect_to two_factor_profile_path, alert: "Please set up 2FA first."
      return
    end

    # Verify the code before enabling
    if @user.verify_otp(params[:otp_code])
      @backup_codes = @user.enable_otp!
      render :backup_codes
    else
      @provisioning_uri = @user.otp_provisioning_uri
      @qr_code = generate_qr_code(@provisioning_uri)
      flash.now[:alert] = "Invalid verification code. Please try again."
      render :two_factor, status: :unprocessable_entity
    end
  end

  def regenerate_backup_codes
    @user = Current.user

    unless @user.otp_enabled?
      redirect_to two_factor_profile_path, alert: "2FA is not enabled."
      return
    end

    # Require password confirmation
    unless @user.authenticate(params[:password])
      redirect_to two_factor_profile_path, alert: "Invalid password."
      return
    end

    @backup_codes = @user.generate_backup_codes!
    flash.now[:notice] = "New backup codes generated. Your old codes are now invalid."
    render :backup_codes
  end

  def disable_two_factor
    @user = Current.user

    # Require password confirmation to disable 2FA
    unless @user.authenticate(params[:password])
      redirect_to two_factor_profile_path, alert: "Invalid password."
      return
    end

    @user.disable_otp!
    redirect_to profile_path, notice: "Two-factor authentication disabled."
  end

  private

  def generate_qr_code(uri)
    return nil unless uri

    qrcode = RQRCode::QRCode.new(uri)
    qrcode.as_svg(
      offset: 0,
      color: "000",
      shape_rendering: "crispEdges",
      module_size: 4,
      standalone: true
    )
  end

  def profile_params
    params.require(:user).permit(:name)
  end

  def password_params
    params.require(:user).permit(:password, :password_confirmation)
  end
end
