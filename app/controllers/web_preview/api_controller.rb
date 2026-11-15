# frozen_string_literal: true

class WebPreview::APIController < ApplicationController
  include WebPreviewAccess

  ACCOUNT_HEADER = "X-Shelfarr-Account"

  before_action :private_response
  rescue_from ActionController::InvalidAuthenticityToken, with: -> { render_error("invalid_csrf", :unprocessable_entity) }
  rescue_from ActiveRecord::RecordNotFound, with: -> { render_error("not_found", :not_found) }

  private

  def web_preview_verify_account
    render_error("account_changed", :unauthorized) unless request.headers[ACCOUNT_HEADER] == web_preview_account_id
  end

  def web_preview_not_found
    render_error("not_found", :not_found)
  end

  def web_preview_signed_out
    render_error("signed_out", :unauthorized)
  end

  def render_error(code, status, message: nil)
    render json: { error: code, message: message }.compact, status: status
  end

  def private_response
    headers["Cache-Control"] = "private, no-store"
    headers["X-Content-Type-Options"] = "nosniff"
  end
end
