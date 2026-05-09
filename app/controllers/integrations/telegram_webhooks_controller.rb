# frozen_string_literal: true

module Integrations
  class TelegramWebhooksController < ActionController::API
    rescue_from ActionDispatch::Http::Parameters::ParseError, with: :bad_request

    def create
      unless Integrations::Telegram::Configuration.webhook_secret_valid?(request.headers["X-Telegram-Bot-Api-Secret-Token"])
        head :unauthorized
        return
      end

      update = record_update
      unless update
        head :ok
        return
      end

      unless Integrations::Telegram::RateLimiter.allowed?(update.telegram_user_id)
        render json: {
          method: "sendMessage",
          chat_id: update.chat_id,
          text: "Too many Telegram commands. Try again in a minute."
        }
        return
      end

      response = Integrations::Telegram::CommandHandler.call(payload: request.request_parameters)
      if response&.deliverable?
        render json: response.to_telegram_payload
      else
        head :ok
      end
    end

    private

    def bad_request
      render json: { ok: false, error: "JSON invalid" }, status: :bad_request
    end

    def record_update
      update_id = request.request_parameters["update_id"].to_s
      return nil if update_id.blank?

      TelegramUpdate.create!(
        update_id: update_id,
        telegram_user_id: telegram_user_id,
        chat_id: chat_id,
        command: command_text
      )
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      nil
    end

    def message
      request.request_parameters["message"] ||
        request.request_parameters["edited_message"] ||
        request.request_parameters.dig("callback_query", "message")
    end

    def callback_query
      request.request_parameters["callback_query"]
    end

    def telegram_user_id
      (callback_query&.dig("from", "id") || message&.dig("from", "id")).to_s
    end

    def chat_id
      message&.dig("chat", "id").to_s
    end

    def command_text
      callback_query&.dig("data").presence || message&.dig("text").to_s.split(/\s+/, 2).first
    end
  end
end
