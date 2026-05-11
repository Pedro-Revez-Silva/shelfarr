class Current < ActiveSupport::CurrentAttributes
  attribute :session, :api_user, :api_token, :legacy_api_token_authenticated

  def user
    session&.user || api_user
  end

  def api_admin?
    legacy_api_token_authenticated || api_user&.admin? || api_token&.has_scope?("requests:admin")
  end

  def api_scope?(scope)
    legacy_api_token_authenticated || api_token&.has_scope?(scope)
  end
end
