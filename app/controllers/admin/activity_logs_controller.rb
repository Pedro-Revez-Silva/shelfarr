# frozen_string_literal: true

module Admin
  class ActivityLogsController < BaseController
    before_action :open_warm_page, only: :index

    def index
      @logs = ActivityLog.listing(user_id: params[:user_id], action: params[:action_filter], from: params[:from])
        .includes(:user, :trackable).limit(ActivityLog::LIST_LIMIT)

      @users = User.order(:name)
      @actions = ActivityLog.distinct.pluck(:action).sort
    end

    private

    def open_warm_page
      return unless request.format.html? && flash.empty? && WebPreview::Access.current.allows?(Current.user) && WarmEntry.stylesheet_built?

      address = WebPreview::ActivityFilters.warm_address(params)
      redirect_to [ web_preview_server_activity_path, address.to_query.presence ].compact.join("?") if address
    end
  end
end
