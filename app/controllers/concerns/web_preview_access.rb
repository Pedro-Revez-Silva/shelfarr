# frozen_string_literal: true

module WebPreviewAccess
  extend ActiveSupport::Concern

  included do
    skip_before_action :require_authentication
    prepend_before_action :enforce_web_preview_access
  end

  private

  def enforce_web_preview_access
    return web_preview_not_found unless WebPreview::Access.current.configured?
    return web_preview_signed_out unless resume_session
    return web_preview_refused unless WebPreview::Access.current.allows?(Current.user)

    web_preview_verify_account
  end

  def web_preview_refused
    rotate_offline_continuity
    web_preview_not_found
  end

  def web_preview_verify_account
  end

  def web_preview_account_id
    Current.user.id.to_s
  end
end
