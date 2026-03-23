# frozen_string_literal: true

class NotificationService
  class << self
    def request_completed(request)
      create_for_user(
        user: request.user,
        notifiable: request,
        type: "request_completed",
        title: "Book Ready",
        message: "\"#{request.book.title}\" is now available for download."
      )
      send_webhook("request_completed", "Book Ready", "\"#{request.book.title}\" is now available.")
    end

    def request_failed(request)
      create_for_user(
        user: request.user,
        notifiable: request,
        type: "request_failed",
        title: "Request Failed",
        message: "\"#{request.book.title}\" could not be downloaded."
      )
      send_webhook("request_failed", "Request Failed", "\"#{request.book.title}\" could not be downloaded.")
    end

    def request_attention(request)
      create_for_user(
        user: request.user,
        notifiable: request,
        type: "request_attention",
        title: "Attention Needed",
        message: "\"#{request.book.title}\" needs your attention."
      )
      send_webhook("request_attention", "Attention Needed", "\"#{request.book.title}\" needs manual selection.")
    end

    def request_created(request)
      create_for_user(
        user: request.user,
        notifiable: request,
        type: "request_created",
        title: "New Request",
        message: "\"#{request.book.title}\" requested by #{request.user.username}."
      )
      send_webhook("request_created", "New Request", "\"#{request.book.title}\" requested by #{request.user.username}.")
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

    def send_webhook(event, title, message)
      return unless SettingsService.get(:webhook_enabled, default: false)

      url = SettingsService.get(:webhook_url)
      return if url.blank?

      enabled_events = (SettingsService.get(:webhook_events) || "").split(",").map(&:strip)
      return unless enabled_events.include?(event)

      Thread.new do
        begin
          token = SettingsService.get(:webhook_token)
          headers = { "Content-Type" => "text/plain" }

          if token.present?
            headers["Authorization"] = token.start_with?("Bearer ") ? token : "Bearer #{token}"
          end

          # ntfy-style: title in header, message in body
          headers["Title"] = title

          conn = Faraday.new do |f|
            f.options.timeout = 10
            f.options.open_timeout = 5
          end

          response = conn.post(url) do |req|
            req.headers = headers
            req.body = message
          end

          if response.success?
            Rails.logger.info "[NotificationService] Webhook sent: #{event} — #{title}"
          else
            Rails.logger.warn "[NotificationService] Webhook failed (#{response.status}): #{response.body.to_s.truncate(200)}"
          end
        rescue => e
          Rails.logger.error "[NotificationService] Webhook error: #{e.message}"
        end
      end
    end
  end
end
