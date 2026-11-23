# frozen_string_literal: true

module WebPreview
  class UploadJson
    BOOK_TYPES = %w[ebook audiobook comicbook].freeze
    STATUSES = %w[pending processing completed failed].freeze
    TEXT_LIMIT = 300
    MEMBER_FAILURE = "This file could not be added to the library. An administrator can retry it."

    def self.formats
      {
        audiobook: Upload::AUDIOBOOK_EXTENSIONS,
        ebook: Upload::EBOOK_EXTENSIONS,
        comicbook: Upload::COMICBOOK_EXTENSIONS
      }
    end

    def initialize(upload, viewer:)
      @upload = upload
      @viewer = viewer
    end

    def as_json(*)
      value = {
        id: @upload.id.to_s,
        filename: @upload.original_filename.to_s.first(TEXT_LIMIT),
        size: @upload.file_size,
        book_type: BOOK_TYPES.include?(@upload.book_type) ? @upload.book_type : nil,
        status: STATUSES.include?(@upload.status) ? @upload.status : "failed",
        created_at: @upload.created_at.iso8601(3),
        processed_at: @upload.processed_at&.iso8601(3),
        parsed: parsed,
        book: book,
        request_id: request_id,
        uploaded_by_you: @upload.user_id == @viewer.id,
        failure: failure
      }
      admin? ? value.merge(administration) : value
    end

    private

    def admin?
      @viewer.admin?
    end

    def parsed
      return if @upload.parsed_title.blank?

      { title: @upload.parsed_title.to_s.first(TEXT_LIMIT), author: @upload.parsed_author.presence&.first(TEXT_LIMIT), confidence: @upload.match_confidence }
    end

    def book
      book = @upload.book
      return unless book

      readable = book.acquired? && Consumer::LibraryScope.types(nil, graphic: true).include?(book.book_type)
      { title: book.title.to_s.first(TEXT_LIMIT), author: book.author.presence&.first(TEXT_LIMIT), acquired: book.acquired?, publication_id: readable ? book.id.to_s : nil }
    end

    def request_id
      return if @upload.request_id.nil?
      return unless admin? || @upload.request&.user_id == @viewer.id

      @upload.request_id.to_s
    end

    def failure
      return unless @upload.failed?

      admin? ? SecretRedaction.call(@upload.error_message.to_s.scrub).presence&.first(TEXT_LIMIT) : MEMBER_FAILURE
    end

    def administration
      {
        uploaded_by: @upload.user&.name.to_s,
        manual_match: @upload.manual_match?,
        reserved_file: @upload.failed? && @upload.recovery_state?,
        actions: { retry: @upload.failed?, match: @upload.manual_match_available?, remove: true }
      }
    end
  end
end
