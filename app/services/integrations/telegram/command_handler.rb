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
        return reply("This chat is not allowed to use Shelfarr.") unless Configuration.chat_allowed?(chat_id)

        return handle_callback if callback_query

        command, arguments = parse_command
        return nil unless command

        return link(arguments) if command == "/link"
        return reply("Your Telegram account is not linked to a Shelfarr user. Generate a link code in Shelfarr, then use /link <username> <code>.") unless shelfarr_user

        process(command, arguments)
      end

      private

      attr_reader :payload, :message, :callback_query

      def chat_id
        (message || callback_query&.dig("message")).dig("chat", "id").to_s
      end

      def sender_id
        (callback_query&.dig("from", "id") || message&.dig("from", "id")).to_s
      end

      def shelfarr_user
        @shelfarr_user ||= Configuration.user_for(sender_id)
      end

      def text
        message["text"].to_s.strip
      end

      def handle_callback
        return reply("Your Telegram account is not linked to a Shelfarr user.") unless shelfarr_user

        action, work_id, requested_type = callback_query["data"].to_s.split("|", 3)
        return reply("Unknown action.") unless action == "request"

        process("/request", [ work_id, requested_type ].compact.join(" "))
      end

      def parse_command
        token, arguments = text.split(/\s+/, 2)
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

      def link(arguments)
        username, code = arguments.to_s.split(/\s+/, 2)
        return reply("Usage: /link <username> <code>") if username.blank? || code.blank?

        user = User.active.find_by(username: username.to_s.strip.downcase)
        return reply("Invalid or expired link code.") unless user&.telegram_link_code_valid?(code)

        user.link_telegram_identity!(
          telegram_user_id: sender_id,
          telegram_username: message.dig("from", "username")
        )
        @shelfarr_user = user

        reply("Telegram linked to #{user.username}.")
      rescue ActiveRecord::RecordInvalid
        reply("This Telegram account is already linked to another Shelfarr user.")
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
        result = Integrations::CommandProcessor.call(
          command: command,
          arguments: arguments,
          user: shelfarr_user,
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
