# frozen_string_literal: true

class DiscordNotificationDeliveryJob < ApplicationJob
  queue_as :default

  retry_on OutboundNotifications::DiscordDelivery::DeliveryError, wait: 10.seconds, attempts: 3
  discard_on OutboundNotifications::DiscordDelivery::ConfigurationError

  def perform(event:, title:, message:, request_id: nil)
    return unless OutboundNotifications::DiscordDelivery.enabled_for?(event)

    request = Request.includes(:book, :user).find_by(id: request_id) if request_id.present?

    OutboundNotifications::DiscordDelivery.deliver!(
      event: event,
      title: title,
      message: message,
      request: request
    )
  end
end
