# frozen_string_literal: true

class WebPreview::MediaController < WebPreview::APIController
  include ConsumerMediaResponse
  include ConsumerWebPublication

  prepend_before_action :refuse_cross_site_fetch
  prepend_before_action :media_privacy

  def show
    serve_consumer_asset(web_book(params[:id]), params[:asset_id])
  end

  private

  def media_privacy
    headers["Cache-Control"] = "private, no-store"
    headers["Cross-Origin-Resource-Policy"] = "same-origin"
    headers["Referrer-Policy"] = "no-referrer"
    headers["X-Content-Type-Options"] = "nosniff"
    headers["Content-Security-Policy"] = ConsumerMediaResponse::DOCUMENT_POLICY
  end

  def web_preview_verify_account
    render_error("account_changed", :unauthorized) unless params[:account] == web_preview_account_id
  end
end
