# frozen_string_literal: true

class WebPreview::NotificationsController < WebPreview::APIController
  IDENTIFIER = /\A[1-9]\d{0,18}\z/

  def index
    listing = Notification.transaction do
      counts.merge(items: notifications.recent.includes(:notifiable).map { |notification| item(notification) })
    end
    render json: listing
  end

  def mark_read
    raise ActiveRecord::RecordNotFound unless identifier?(params[:id])

    answer do
      notification = notifications.find(params[:id])
      changed = notification.read? ? 0 : 1
      notification.mark_as_read!
      changed
    end
  end

  def mark_all_read
    seen = seen_through
    return render_error("invalid_request", :bad_request) unless seen

    answer { notifications.unread.where(id: ..seen).update_all(read_at: Time.current) }
  end

  def clear
    seen = seen_through
    return render_error("invalid_request", :bad_request) unless seen

    answer { notifications.where(id: ..seen).delete_all }
  end

  private

  def notifications
    Current.user.notifications
  end

  def answer
    outcome = Notification.transaction do
      changed = yield
      counts.merge(changed: changed)
    end
    render json: outcome
  end

  def seen_through
    params[:through].to_i if identifier?(params[:through])
  end

  def identifier?(value)
    value.is_a?(String) && value.match?(IDENTIFIER)
  end

  def counts
    { account: web_preview_account_id, unread: notifications.unread.count, total: notifications.count }
  end

  def item(notification)
    {
      id: notification.id.to_s,
      type: notification.notification_type,
      title: notification.title,
      message: notification.message.presence,
      created_at: notification.created_at.iso8601(3),
      read_at: notification.read_at&.iso8601(3),
      request: request_target(notification)
    }
  end

  def request_target(notification)
    return nil unless notification.notifiable_type == "Request"

    request = notification.notifiable
    visible = request && (request.user_id == Current.user.id || Current.user.admin?)
    visible ? { state: "available", id: request.id.to_s } : { state: "unavailable" }
  end
end
