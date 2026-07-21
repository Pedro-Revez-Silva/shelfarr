# frozen_string_literal: true

module Integrations
  class TelegramWebhooksController < ActionController::API
    rescue_from ActionDispatch::Http::Parameters::ParseError, with: :bad_request

    def create
      unless Integrations::Telegram::Configuration.webhook?
        head :not_found
        return
      end

      unless Integrations::Telegram::Configuration.webhook_secret_valid?(request.headers["X-Telegram-Bot-Api-Secret-Token"])
        head :unauthorized
        return
      end

      response = Integrations::Telegram::UpdateProcessor.call(payload: request.request_parameters)
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
  end
end
