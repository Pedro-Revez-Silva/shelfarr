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

    def initialize(command:, arguments:, user:, origin: {}, request_selection: nil)
      @command = command.to_s.downcase
      @arguments = arguments.to_s.strip
      @user = user
      @origin = origin
      @request_selection = request_selection&.to_h&.symbolize_keys
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

    attr_reader :command, :arguments, :user, :origin, :request_selection

    def help_text
      [
        "Shelfarr commands:",
        "/search <title or author>",
        "/request <work_id> <ebook|audiobook|comicbook|both> [language]",
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
        lines << "#{index + 1}. #{search_result.title}#{author_suffix(search_result)}#{source_suffix(search_result)}"
      end
      lines << "Choose a format below."

      result(lines.join("\n"), search_results: results)
    rescue HardcoverClient::ConnectionError, GoogleBooksClient::ConnectionError, OpenLibraryClient::ConnectionError
      result("Shelfarr could not reach the metadata service.")
    rescue HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, MetadataService::Error
      result("Search failed. Try again later.")
    end

    def create_request(raw_arguments)
      if request_selection.present?
        work_id = request_selection[:work_id]
        source_work_ids = request_selection[:source_work_ids]
        metadata_attrs = request_selection[:metadata_attrs] || {}
        requested_type, language = raw_arguments.to_s.split(/\s+/, 2)
        book_types = book_types_for(requested_type)
      else
        work_id, requested_type, language = raw_arguments.to_s.split(/\s+/, 3)
        source_work_ids = nil
        metadata_attrs = {}
        book_types = book_types_for(requested_type)
      end

      if work_id.blank? || book_types.empty?
        return result("Usage: /request <work_id> <ebook|audiobook|comicbook|both> [language]")
      end

      creation = RequestCreationService.call(
        user: user,
        work_id: work_id,
        source_work_ids: source_work_ids,
        book_types: book_types,
        metadata_attrs: metadata_attrs,
        language: language,
        origin: origin
      )

      if creation.queued?
        result("Collection request queued. Individual requests will be created shortly.")
      elsif creation.success?
        created = creation.created_requests.map { |request| "#{request.book.display_name} (#{request.book.book_type})" }
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
      when "comicbook"
        [ "comicbook" ]
      when "both"
        [ "ebook", "audiobook" ]
      else
        []
      end
    end

    def author_suffix(search_result)
      search_result.author.present? ? " by #{search_result.author}" : ""
    end

    def source_suffix(search_result)
      source_names = if search_result.respond_to?(:sources)
        search_result.sources.map { |source| source[:source_name] }
      else
        [ search_result.source_name ]
      end.compact_blank

      source_names.any? ? " (#{source_names.join(', ')})" : ""
    end

    def result(text, search_results: [])
      Result.new(text: text, search_results: search_results)
    end
  end
end
