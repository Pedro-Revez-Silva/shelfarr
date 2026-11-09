class Current < ActiveSupport::CurrentAttributes
  attribute :session, :api_user, :api_token, :legacy_api_token_authenticated

  def user
    session&.user || api_user
  end

  def api_admin?
    return true if legacy_api_token_authenticated
    # A native app credential acts only for its own account, even for an admin.
    return false if api_token&.consumer_device?

    api_user&.admin? || api_token&.has_scope?("requests:admin") || false
  end

  def api_scope?(scope)
    legacy_api_token_authenticated || api_token&.has_scope?(scope)
  end
end
