# frozen_string_literal: true

module OutboundNotifications
  class Dispatcher
    class << self
      def notify(event:, request:, title:, message:)
        if OutboundNotifications::WebhookDelivery.enabled_for?(event)
          OutboundWebhookDeliveryJob.perform_later(
            event: event,
            request_id: request&.id,
            title: title,
            message: message
          )
        end

        if OutboundNotifications::DiscordDelivery.enabled_for?(event)
          DiscordNotificationDeliveryJob.perform_later(
            event: event,
            request_id: request&.id,
            title: title,
            message: message
          )
        end

        if request&.id && Integrations::Telegram::Configuration.notification_enabled_for?(event)
          TelegramNotificationDeliveryJob.perform_later(event: event, request_id: request.id)
        end
      end
    end
  end
end
