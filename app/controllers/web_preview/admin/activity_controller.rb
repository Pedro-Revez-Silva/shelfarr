# frozen_string_literal: true

class WebPreview::Admin::ActivityController < WebPreview::Admin::BaseController
  rescue_from WebPreview::ActivityFilters::Invalid, with: -> { render_error("invalid_request", :bad_request) }

  def index
    filters = WebPreview::ActivityFilters.parse(params)
    logs = ActivityLog.listing(**filters).includes(:user, :trackable).limit(ActivityLog::LIST_LIMIT + 1).to_a
    render json: {
      account: web_preview_account_id,
      limit: ActivityLog::LIST_LIMIT,
      more: logs.size > ActivityLog::LIST_LIMIT,
      entries: WebPreview::ActivityJson.new(logs.first(ActivityLog::LIST_LIMIT)).entries,
      people: User.order(:name, :id).map { |user| WebPreview::ActivityJson.person(user) },
      actions: ActivityLog.distinct.pluck(:action).sort
    }
  end
end
