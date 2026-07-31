# frozen_string_literal: true

class NotificationService
  class << self
    def request_created(request)
      dispatch_outbound_event(
        event: "request_created",
        request: request,
        title: "New Request",
        message: "\"#{request.book.title}\" requested by #{request.user.username}."
      )
    end

    def request_completed(request)
      create_for_user(
        user: request.user,
        notifiable: request,
        type: "request_completed",
        title: "Book Ready",
        message: "\"#{request.book.title}\" is now available for download."
      )
      dispatch_outbound_event(
        event: "request_completed",
        request: request,
        title: "Book Ready",
        message: "\"#{request.book.title}\" is now available for download."
      )
    end

    def request_failed(request)
      create_for_user(
        user: request.user,
        notifiable: request,
        type: "request_failed",
        title: "Request Failed",
        message: "\"#{request.book.title}\" could not be downloaded."
      )
      dispatch_outbound_event(
        event: "request_failed",
        request: request,
        title: "Request Failed",
        message: "\"#{request.book.title}\" could not be downloaded."
      )
    end

    def request_attention(request)
      create_for_user(
        user: request.user,
        notifiable: request,
        type: "request_attention",
        title: "Attention Needed",
        message: "\"#{request.book.title}\" needs your attention."
      )
      dispatch_outbound_event(
        event: "request_attention",
        request: request,
        title: "Attention Needed",
        message: "\"#{request.book.title}\" needs your attention."
      )
    end

    # Batched notification that new watched-folder files were detected and are
    # waiting for review. Import is an admin action, so only admins are notified
    # in-app; outbound channels fire if the "import_detected" event is enabled.
    def import_detected(count:)
      return if count.to_i <= 0

      noun = count == 1 ? "book file" : "book files"
      title = "New #{count == 1 ? 'file' : 'files'} detected"
      message = "#{count} new #{noun} detected in your watched folder and #{count == 1 ? 'is' : 'are'} waiting for review."

      User.active.where(role: :admin).find_each do |admin|
        create_for_user(
          user: admin,
          notifiable: nil,
          type: "import_detected",
          title: title,
          message: message
        )
      end

      dispatch_outbound_event(
        event: "import_detected",
        request: nil,
        title: title,
        message: message
      )
    end

    private

    def create_for_user(user:, notifiable:, type:, title:, message:)
      user.notifications.create!(
        notifiable: notifiable,
        notification_type: type,
        title: title,
        message: message
      )
    rescue => e
      Rails.logger.error "[NotificationService] Failed to create notification: #{e.message}"
      nil
    end

    def dispatch_outbound_event(event:, request:, title:, message:)
      OutboundNotifications::Dispatcher.notify(
        event: event,
        request: request,
        title: title,
        message: message
      )
    rescue => e
      Rails.logger.error "[NotificationService] Failed to enqueue outbound notification: #{e.message}"
      nil
    end
  end
end
