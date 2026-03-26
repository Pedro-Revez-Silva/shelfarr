# frozen_string_literal: true

class OutboundWebhookDeliveryJob < ApplicationJob
  queue_as :default

  retry_on OutboundNotifications::WebhookDelivery::DeliveryError, wait: 10.seconds, attempts: 3
  discard_on OutboundNotifications::WebhookDelivery::ConfigurationError

  def perform(event:, title:, message:, request_id: nil)
    return unless OutboundNotifications::WebhookDelivery.enabled_for?(event)

    request = Request.includes(:book, :user).find_by(id: request_id) if request_id.present?

    OutboundNotifications::WebhookDelivery.deliver!(
      event: event,
      title: title,
      message: message,
      request: request
    )
  end
end
