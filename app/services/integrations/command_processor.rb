# frozen_string_literal: true

module Integrations
  class CommandProcessor
    MAX_SEARCH_RESULTS = 5
    MAX_STATUS_RESULTS = 5

    Result = Data.define(:text, :search_results)

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(command:, arguments:, user:, origin: {})
      @command = command.to_s.downcase
      @arguments = arguments.to_s.strip
      @user = user
      @origin = origin
    end

    def call
      case command
      when "/help", "/start"
        result(help_text)
      when "/whoami"
        result("Telegram requests are owned by #{user.username}.")
      when "/search"
        search(arguments)
      when "/request"
        create_request(arguments)
      when "/status"
        status
      else
        result("Unknown command. Use /help for available commands.")
      end
    end

    private

    attr_reader :command, :arguments, :user, :origin

    def help_text
      [
        "Shelfarr commands:",
        "/search <title or author>",
        "/request <work_id> <ebook|audiobook|both> [language]",
        "/status",
        "/whoami"
      ].join("\n")
    end

    def search(query)
      return result("Usage: /search <title or author>") if query.blank?

      results = MetadataService.search(query, limit: MAX_SEARCH_RESULTS)
      return result("No results found for #{query}.") if results.empty?

      lines = [ "Search results for #{query}:" ]
      results.each_with_index do |search_result, index|
        lines << "#{index + 1}. #{search_result.title}#{author_suffix(search_result)}"
        lines << "   #{search_result.work_id}"
      end

      result(lines.join("\n"), search_results: results)
    rescue HardcoverClient::ConnectionError, OpenLibraryClient::ConnectionError
      result("Shelfarr could not reach the metadata service.")
    rescue HardcoverClient::Error, OpenLibraryClient::Error, MetadataService::Error
      result("Search failed. Try again later.")
    end

    def create_request(raw_arguments)
      work_id, requested_type, language = raw_arguments.to_s.split(/\s+/, 3)
      book_types = book_types_for(requested_type)

      if work_id.blank? || book_types.empty?
        return result("Usage: /request <work_id> <ebook|audiobook|both> [language]")
      end

      creation = RequestCreationService.call(
        user: user,
        work_id: work_id,
        book_types: book_types,
        language: language,
        origin: origin
      )

      if creation.success?
        created = creation.created_requests.map { |request| "#{request.book.book_type}: #{request.book.display_name}" }
        lines = [ "Request created:", *created ]
        lines << "Warnings: #{creation.warnings.join('; ')}" if creation.warnings.any?
        lines << "Errors: #{creation.errors.join('; ')}" if creation.errors.any?
        result(lines.join("\n"))
      else
        result("Request could not be created: #{creation.errors.join('; ')}")
      end
    end

    def status
      requests = status_scope.includes(:book).order(created_at: :desc).limit(MAX_STATUS_RESULTS)
      return result("No requests found.") if requests.empty?

      lines = [ "Latest Shelfarr requests:" ]
      requests.each do |request|
        lines << "#{request.book.display_name} (#{request.book.book_type}) - #{request.status}"
      end

      result(lines.join("\n"))
    end

    def status_scope
      if origin[:external_source] == "telegram" && origin[:external_chat_id].present?
        Request.where(external_source: "telegram", external_chat_id: origin[:external_chat_id])
      else
        user.requests
      end
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

    def author_suffix(search_result)
      search_result.author.present? ? " by #{search_result.author}" : ""
    end

    def result(text, search_results: [])
      Result.new(text: text, search_results: search_results)
    end
  end
end
