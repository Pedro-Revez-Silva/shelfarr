# frozen_string_literal: true

module Integrations
  module Telegram
    class CommandHandler
      MAX_SEARCH_RESULTS = 5
      MAX_STATUS_RESULTS = 5

      Response = Data.define(:chat_id, :text) do
        def deliverable?
          chat_id.present? && text.present?
        end

        def to_telegram_payload
          {
            method: "sendMessage",
            chat_id: chat_id,
            text: text,
            disable_web_page_preview: true
          }
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
      end

      def call
        return nil unless message
        return reply("Telegram integration is not enabled.") unless Configuration.configured?
        return reply("This chat is not allowed to use Shelfarr.") unless Configuration.chat_allowed?(chat_id)
        return reply("Your Telegram account is not linked to a Shelfarr user.") unless shelfarr_user

        command, arguments = parse_command
        return nil unless command

        case command
        when "/help", "/start"
          help
        when "/whoami"
          reply("Linked as #{shelfarr_user.username}.")
        when "/search"
          search(arguments)
        when "/request"
          create_request(arguments)
        when "/status"
          status
        else
          reply("Unknown command. Use /help for available commands.")
        end
      end

      private

      attr_reader :payload, :message

      def chat_id
        message.dig("chat", "id").to_s
      end

      def sender_id
        message.dig("from", "id").to_s
      end

      def shelfarr_user
        @shelfarr_user ||= Configuration.user_for(sender_id)
      end

      def text
        message["text"].to_s.strip
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

      def help
        reply(
          [
            "Shelfarr commands:",
            "/search <title or author>",
            "/request <work_id> <ebook|audiobook|both> [language]",
            "/status",
            "/whoami"
          ].join("\n")
        )
      end

      def search(query)
        return reply("Usage: /search <title or author>") if query.blank?

        results = MetadataService.search(query, limit: MAX_SEARCH_RESULTS)
        return reply("No results found for #{query}.") if results.empty?

        lines = [ "Search results for #{query}:" ]
        results.each_with_index do |result, index|
          lines << "#{index + 1}. #{result.title}#{author_suffix(result)}"
          lines << "   #{result.work_id}"
          lines << "   /request #{result.work_id} ebook"
        end

        reply(lines.join("\n"))
      rescue HardcoverClient::ConnectionError, OpenLibraryClient::ConnectionError
        reply("Shelfarr could not reach the metadata service.")
      rescue HardcoverClient::Error, OpenLibraryClient::Error, MetadataService::Error
        reply("Search failed. Try again later.")
      end

      def create_request(arguments)
        work_id, requested_type, language = arguments.to_s.split(/\s+/, 3)
        book_types = book_types_for(requested_type)

        if work_id.blank? || book_types.empty?
          return reply("Usage: /request <work_id> <ebook|audiobook|both> [language]")
        end

        result = RequestCreationService.call(
          user: shelfarr_user,
          work_id: work_id,
          book_types: book_types,
          language: language
        )

        if result.success?
          created = result.created_requests.map { |request| "#{request.book.book_type}: #{request.book.display_name}" }
          lines = [ "Request created:", *created ]
          lines << "Warnings: #{result.warnings.join('; ')}" if result.warnings.any?
          lines << "Errors: #{result.errors.join('; ')}" if result.errors.any?
          reply(lines.join("\n"))
        else
          reply("Request could not be created: #{result.errors.join('; ')}")
        end
      end

      def status
        requests = shelfarr_user.requests.includes(:book).order(created_at: :desc).limit(MAX_STATUS_RESULTS)
        return reply("No requests found.") if requests.empty?

        lines = [ "Latest Shelfarr requests:" ]
        requests.each do |request|
          lines << "#{request.book.display_name} (#{request.book.book_type}) - #{request.status}"
        end

        reply(lines.join("\n"))
      end

      def book_types_for(value)
        case value.to_s.downcase
        when "ebook"
          [ "ebook" ]
        when "audiobook"
          [ "audiobook" ]
        when "both"
          [ "ebook", "audiobook" ]
        else
          []
        end
      end

      def author_suffix(result)
        result.author.present? ? " by #{result.author}" : ""
      end

      def reply(text)
        Response.new(chat_id: chat_id, text: text)
      end
    end
  end
end
