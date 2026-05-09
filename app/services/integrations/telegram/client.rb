# frozen_string_literal: true

module Integrations
  module Telegram
    class Client
      class ConfigurationError < StandardError; end
      class DeliveryError < StandardError; end

      MAX_MESSAGE_LENGTH = 3900

      class << self
        def get_me
          new.get_me
        end

        def set_webhook!(url:)
          new.set_webhook!(url: url)
        end

        def send_message(chat_id:, text:, reply_markup: nil)
          new.send_message(chat_id: chat_id, text: text, reply_markup: reply_markup)
        end
      end

      def get_me
        post("getMe", {})
      end

      def set_webhook!(url:)
        payload = { url: url }
        secret = Configuration.webhook_secret
        payload[:secret_token] = secret if secret.present?
        post("setWebhook", payload)
      end

      def send_message(chat_id:, text:, reply_markup: nil)
        split_text(text).each do |chunk|
          payload = {
            chat_id: chat_id,
            text: chunk,
            disable_web_page_preview: true
          }
          payload[:reply_markup] = reply_markup if reply_markup.present?
          post("sendMessage", payload)
        end
      end

      private

      def post(method, payload)
        raise ConfigurationError, "Telegram bot token is not configured." if Configuration.bot_token.blank?

        response = connection.post(method) do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = payload.to_json
        end

        parsed = parse_body(response.body)
        return parsed if response.success? && parsed["ok"] != false

        description = parsed["description"].presence || response.body.to_s.truncate(200)
        raise DeliveryError, "Telegram #{method} failed: #{description}"
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
        raise DeliveryError, "Telegram connection failed: #{e.message}"
      end

      def connection
        Faraday.new(url: "https://api.telegram.org/bot#{Configuration.bot_token}/") do |f|
          f.options.timeout = 10
          f.options.open_timeout = 5
        end
      end

      def parse_body(body)
        JSON.parse(body.to_s.presence || "{}")
      rescue JSON::ParserError
        {}
      end

      def split_text(text)
        value = text.to_s
        return [ "" ] if value.blank?

        value.scan(/.{1,#{MAX_MESSAGE_LENGTH}}/m)
      end
    end
  end
end
