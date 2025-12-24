module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      return nil unless cookies.signed[:session_id]

      session = Session.find_by(id: cookies.signed[:session_id])
      return nil unless session

      # Check if session has expired (default 30 days)
      max_age_days = SettingsService.get(:session_max_age_days, default: 30)
      if session.created_at < max_age_days.days.ago
        session.destroy
        cookies.delete(:session_id)
        return nil
      end

      session
    end

    def request_authentication
      # Redirect to setup if no users exist
      if User.none?
        redirect_to sign_up_path
        return
      end

      session[:return_to_after_authenticating] = request.url
      redirect_to new_session_path
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || root_url
    end

    def start_new_session_for(user)
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        max_age_days = SettingsService.get(:session_max_age_days, default: 30)
        cookies.signed[:session_id] = {
          value: session.id,
          expires: max_age_days.days.from_now,
          httponly: true,
          same_site: :lax,
          secure: Rails.env.production?
        }
      end
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(:session_id)
    end
end
