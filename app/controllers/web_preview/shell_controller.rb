# frozen_string_literal: true

class WebPreview::ShellController < ApplicationController
  include WebPreviewAccess

  CONTENT_SECURITY_POLICY = [
    "default-src 'none'", "script-src 'self'", "style-src 'self'", "font-src 'self'", "img-src 'self' https: data:",
    "connect-src 'self'", "manifest-src 'self'", "form-action 'self'", "base-uri 'self'", "frame-ancestors 'self'", "object-src 'none'"
  ].join("; ").freeze

  def index
    redirect_to web_preview_library_path, status: :see_other
  end

  def show
    headers["Cache-Control"] = "private, no-store"
    headers["Content-Security-Policy"] = CONTENT_SECURITY_POLICY
    @boot = {
      version: 1,
      account: web_preview_account_id,
      mount: web_preview_path,
      api: web_preview_api_session_path.delete_suffix("/session"),
      classic_library: consumer_library_path
    }
    render layout: false
  end

  private

  def web_preview_not_found
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end

  def web_preview_signed_out
    request_authentication
  end
end
