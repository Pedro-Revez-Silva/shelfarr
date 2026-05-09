# frozen_string_literal: true

module Integrations
  module Telegram
    class CommandHandler
      Response = Data.define(:chat_id, :text, :reply_markup) do
        def deliverable?
          chat_id.present? && text.present?
        end

        def to_telegram_payload
          {
            method: "sendMessage",
            chat_id: chat_id,
            text: text.to_s.truncate(3900),
            disable_web_page_preview: true
          }.tap do |payload|
            payload[:reply_markup] = reply_markup if reply_markup.present?
          end
        end
      end

      class << self
        def call(...)
          new(...).call
        end
      end

      def initialize(payload:)
        @payload = payload.to_h
        @message = @payload["message"] || @payload["edited_message"]
        @callback_query = @payload["callback_query"]
      end

      def call
        return nil unless message || callback_query
        return reply("Telegram integration is not enabled.") unless Configuration.configured?
        return reply("Shelfarr only accepts Telegram commands from authorized groups.") unless group_chat?
        return paused_group_reply if Configuration.chat_paused?(chat_id)
        return unauthorized_group_reply unless Configuration.chat_allowed?(chat_id)

        return handle_callback if callback_query

        command, arguments = parse_command
        return nil unless command

        process(command, arguments)
      end

      private

      attr_reader :payload, :message, :callback_query

      def chat_id
        (message || callback_query&.dig("message")).dig("chat", "id").to_s
      end

      def chat
        (message || callback_query&.dig("message")).dig("chat") || {}
      end

      def group_chat?
        %w[group supergroup].include?(chat["type"].to_s)
      end

      def sender_id
        (callback_query&.dig("from", "id") || message&.dig("from", "id")).to_s
      end

      def sender_username
        (callback_query&.dig("from", "username") || message&.dig("from", "username")).to_s
      end

      def request_user
        @request_user ||= Configuration.request_user
      end

      def text
        message["text"].to_s.strip
      end

      def handle_callback
        action, work_id, requested_type = callback_query["data"].to_s.split("|", 3)
        return reply("Unknown action.") unless action == "request"

        process("/request", [ work_id, requested_type ].compact.join(" "))
      end

      def parse_command
        raw_text = text
        mention_token, remaining_text = raw_text.split(/\s+/, 2)

        if mention_token&.start_with?("@")
          return [ nil, nil ] unless bot_mentioned?(mention_token)

          raw_text = remaining_text.to_s.strip
        end

        token, arguments = raw_text.split(/\s+/, 2)
        return [ nil, nil ] unless token&.start_with?("/")

        command, mention = token.split("@", 2)
        return [ nil, nil ] if command_addressed_to_another_bot?(mention)

        [ command.downcase, arguments.to_s.strip ]
      end

      def command_addressed_to_another_bot?(mention)
        mention.present? &&
          Configuration.bot_username.present? &&
          !mention.casecmp(Configuration.bot_username).zero?
      end

      def bot_mentioned?(mention_token)
        username = Configuration.bot_username
        return false if username.blank?

        mention_token.to_s.delete_prefix("@").casecmp(username).zero?
      end

      def unauthorized_group_reply
        _authorization, code = TelegramChatAuthorization.issue!(
          chat_id: chat_id,
          chat_title: chat["title"],
          requested_by_telegram_user_id: sender_id,
          requested_by_telegram_username: sender_username
        )

        reply(
          "This Telegram group is not authorized for Shelfarr. " \
          "Approval code: #{code}. Enter it in Admin > Settings > Integrations > Telegram within 2 minutes."
        )
      end

      def paused_group_reply
        reply("This Telegram group is paused in Shelfarr. Resume it in Admin > Settings > Integrations > Telegram to process commands.")
      end

      def search_keyboard(results)
        {
          inline_keyboard: results.map do |result|
            [
              { text: "Ebook: #{result.title.to_s.truncate(24)}", callback_data: "request|#{result.work_id}|ebook" },
              { text: "Audio", callback_data: "request|#{result.work_id}|audiobook" }
            ]
          end
        }
      end

      def process(command, arguments)
        return reply("Telegram request owner is not configured in Shelfarr.") unless request_user

        result = Integrations::CommandProcessor.call(
          command: command,
          arguments: arguments,
          user: request_user,
          origin: {
            created_via: "telegram",
            external_source: "telegram",
            external_user_id: sender_id,
            external_chat_id: chat_id
          }
        )

        reply(
          result.text,
          reply_markup: result.search_results.any? ? search_keyboard(result.search_results) : nil
        )
      end

      def reply(text, reply_markup: nil)
        Response.new(chat_id: chat_id, text: text, reply_markup: reply_markup)
      end
    end
  end
end
