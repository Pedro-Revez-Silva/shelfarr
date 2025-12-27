class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[new create verify_otp submit_otp]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Try again later." }

  def new
    redirect_to sign_up_path if User.none?
  end

  def create
    user = User.find_by(username: params[:username]&.strip&.downcase)

    # Check if account is locked
    if user&.locked?
      log_security_event("login.blocked_locked", user, params[:username])
      redirect_to new_session_path, alert: "Account is locked. Try again in #{user.unlock_in_words}."
      return
    end

    # Authenticate
    if user&.authenticate(params[:password])
      # Check if 2FA is required
      if user.otp_enabled?
        session[:pending_user_id] = user.id
        redirect_to verify_otp_session_path
      else
        complete_login(user)
      end
    else
      handle_failed_login(user, params[:username])
    end
  end

  # Show OTP verification form
  def verify_otp
    unless session[:pending_user_id]
      redirect_to new_session_path
      return
    end

    @user = User.find_by(id: session[:pending_user_id])
    unless @user
      session.delete(:pending_user_id)
      redirect_to new_session_path
    end
  end

  # Verify submitted OTP code or backup code
  def submit_otp
    user = User.find_by(id: session[:pending_user_id])

    unless user
      redirect_to new_session_path, alert: "Session expired. Please log in again."
      return
    end

    code = params[:otp_code].to_s.strip

    # Try OTP first, then backup code
    if user.verify_otp(code)
      session.delete(:pending_user_id)
      complete_login(user)
    elsif user.verify_backup_code(code)
      session.delete(:pending_user_id)
      log_security_event("login.backup_code_used", user)
      complete_login(user)
      flash[:warning] = "You used a backup code. You have #{user.backup_codes_remaining} codes remaining."
    else
      log_security_event("login.invalid_otp", user)
      redirect_to verify_otp_session_path, alert: "Invalid verification code. Please try again."
    end
  end

  def destroy
    ActivityTracker.track("user.logout")
    terminate_session
    redirect_to new_session_path, status: :see_other
  end

  private

  def complete_login(user)
    user.reset_failed_logins!
    start_new_session_for(user)
    ActivityTracker.track("user.login", user: user)
    log_security_event("login.success", user)
    redirect_to after_authentication_url
  end

  def handle_failed_login(user, attempted_username)
    if user
      user.record_failed_login!(request.remote_ip)
      log_security_event("login.failed", user, attempted_username)

      if user.locked?
        redirect_to new_session_path, alert: "Too many failed attempts. Account locked for #{user.unlock_in_words}."
      else
        remaining = SettingsService.get(:login_lockout_threshold, default: 5) - user.failed_login_count
        redirect_to new_session_path, alert: "Invalid username or password. #{remaining} attempts remaining."
      end
    else
      log_security_event("login.unknown_user", nil, attempted_username)
      redirect_to new_session_path, alert: "Invalid username or password."
    end
  end

  def log_security_event(event_type, user = nil, attempted_username = nil)
    details = {
      event: event_type,
      ip: request.remote_ip,
      user_agent: request.user_agent,
      timestamp: Time.current.iso8601
    }
    details[:user_id] = user.id if user
    details[:username] = user&.username || attempted_username

    Rails.logger.info "[Security] #{event_type}: #{details.to_json}"
  end
end
