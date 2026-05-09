# frozen_string_literal: true

module Integrations
  module Telegram
    class UpdateProcessor
      class << self
        def call(...)
          new(...).call
        end
      end

      def initialize(payload:)
        @payload = payload.to_h
      end

      def call
        update = record_update
        return nil unless update

        unless RateLimiter.allowed?(update.telegram_user_id)
          return CommandHandler::Response.new(
            chat_id: update.chat_id,
            text: "Too many Telegram commands. Try again in a minute.",
            reply_markup: nil
          )
        end

        CommandHandler.call(payload: payload)
      end

      private

      attr_reader :payload

      def record_update
        update_id = payload["update_id"].to_s
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
        payload["message"] ||
          payload["edited_message"] ||
          payload.dig("callback_query", "message")
      end

      def callback_query
        payload["callback_query"]
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
end
