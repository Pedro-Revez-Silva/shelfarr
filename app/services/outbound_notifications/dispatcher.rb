# frozen_string_literal: true

module OutboundNotifications
  class Dispatcher
    class << self
      def notify(event:, request:, title:, message:)
        return unless OutboundNotifications::WebhookDelivery.enabled_for?(event)

        OutboundWebhookDeliveryJob.perform_later(
          event: event,
          request_id: request&.id,
          title: title,
          message: message
        )
      end
    end
  end
end
