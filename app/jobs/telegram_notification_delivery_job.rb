# frozen_string_literal: true

class TelegramNotificationDeliveryJob < ApplicationJob
  queue_as :default

  retry_on Integrations::Telegram::Client::DeliveryError, wait: 10.seconds, attempts: 3
  discard_on Integrations::Telegram::Client::ConfigurationError

  def perform(event:, request_id:)
    return unless Integrations::Telegram::Configuration.notification_enabled_for?(event)

    request = Request.includes(:book).find_by(id: request_id)
    return unless telegram_group_request?(request)

    Integrations::Telegram::Client.send_message(
      chat_id: request.external_chat_id,
      text: message_for(event, request)
    )
  end

  private

  def telegram_group_request?(request)
    request&.external_source == "telegram" &&
      request.external_chat_id.present? &&
      Integrations::Telegram::Configuration.chat_allowed?(request.external_chat_id)
  end

  def message_for(event, request)
    case event
    when "request_completed"
      "\"#{request.book.title}\" is ready."
    when "request_failed"
      "\"#{request.book.title}\" could not be downloaded."
    when "request_attention"
      "\"#{request.book.title}\" needs attention."
    else
      "\"#{request.book.title}\" changed status to #{request.status}."
    end
  end
end
