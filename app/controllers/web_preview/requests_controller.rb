# frozen_string_literal: true

class WebPreview::RequestsController < WebPreview::APIController
  IDENTIFIER = /\A[1-9]\d{0,18}\z/

  before_action :require_admin, only: [ :selection, :search ]

  def selection
    request = Request.find(identifier(params[:id]))
    result = request.search_results.find(identifier(params[:result_id]))
    request.with_lock do
      result.reload
      raise ArgumentError, "This copy can no longer be chosen. The page shows what can be chosen now." unless WebPreview::BookPage.choosing_allowed?(request) && WebPreview::BookPage.choosable?(result)

      request.select_result!(result)
    end
    render json: { account: web_preview_account_id, request: { id: request.id.to_s, status: request.reload.status } }
  rescue ArgumentError => error
    render_error("not_selectable", :conflict, message: error.message.first(300))
  end

  def search
    request = Request.find(identifier(params[:id]))
    request.refresh_search!
    SearchJob.perform_later(request.id)
    render json: { account: web_preview_account_id, request: { id: request.id.to_s, status: request.reload.status } }
  rescue Request::SearchRefreshBlockedError => error
    render_error("search_blocked", :conflict, message: error.message.first(300))
  end

  def cancel
    request = Request.for_user(Current.user).find(identifier(params[:id]))
    return render_error("cannot_cancel", :conflict, message: cancel_message(request)) unless request.can_be_cancelled?

    request.cancel!
    render json: { account: web_preview_account_id, request: { id: request.id.to_s, status: request.reload.status } }
  rescue Request::CancellationBlockedError => error
    render_error("cannot_cancel", :conflict, message: error.message.first(300))
  end

  private

  def require_admin
    render_error("not_found", :not_found) unless Current.user.admin?
  end

  def identifier(value)
    raise ActiveRecord::RecordNotFound unless value.is_a?(String) && value.match?(IDENTIFIER)

    value
  end

  def cancel_message(request)
    return request.upload_cancellation_blocked_message if request.upload_cancellation_blocked?
    return "This request has already finished." if request.completed?

    "This request is being finished on the server and can't be cancelled now."
  end
end
