# frozen_string_literal: true

class NotificationsController < ApplicationController
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def index
    return redirect_to(web_preview_notifications_path) if warm_notifications?

    @notifications = Current.user.notifications.recent.includes(:notifiable)
  end

  def mark_read
    notification = Current.user.notifications.find(params[:id])
    notification.mark_as_read!

    respond_to do |format|
      format.html { redirect_back(fallback_location: notifications_path) }
      format.turbo_stream { render turbo_stream: turbo_stream.remove(notification) }
    end
  end

  def mark_all_read
    Notification.mark_all_read!(Current.user)
    redirect_to notifications_path, notice: "All notifications marked as read."
  end

  def clear_all
    Current.user.notifications.destroy_all
    redirect_to notifications_path, notice: "All notifications cleared."
  end

  private

  def warm_notifications?
    request.format.html? && flash.empty? && WebPreview::Access.current.allows?(Current.user) && WarmEntry.stylesheet_built?
  end

  def record_not_found
    head :not_found
  end
end
