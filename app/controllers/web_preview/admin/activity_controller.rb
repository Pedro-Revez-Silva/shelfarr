# frozen_string_literal: true

class WebPreview::Admin::ActivityController < WebPreview::Admin::BaseController
  rescue_from WebPreview::ActivityFilters::Invalid, with: -> { render_error("invalid_request", :bad_request) }

  def index
    filters = WebPreview::ActivityFilters.parse(params)
    listing = ActivityLog.listing(**filters)
    logs = listing.includes(:user, :trackable).limit(ActivityLog::LIST_LIMIT).to_a
    render json: {
      account: web_preview_account_id,
      limit: ActivityLog::LIST_LIMIT,
      more: listing.offset(ActivityLog::LIST_LIMIT).limit(1).pluck(:id).any?,
      entries: WebPreview::ActivityJson.new(logs).entries,
      people: User.order(:name, :id).map { |user| WebPreview::ActivityJson.person(user) },
      actions: ActivityLog.distinct.pluck(:action).sort
    }
  end
end
