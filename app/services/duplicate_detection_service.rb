# frozen_string_literal: true

# Service for detecting duplicate books and requests
# Returns status and existing records to help users make informed decisions
class DuplicateDetectionService
  # Result status types
  ALLOW = :allow           # No duplicates, proceed
  WARN = :warn             # Similar exists, user can still proceed
  BLOCK = :block           # Exact duplicate, cannot create

  Result = Data.define(:status, :message, :existing_book, :existing_request) do
    def allow?
      status == ALLOW
    end

    def warn?
      status == WARN
    end

    def block?
      status == BLOCK
    end
  end

  class << self
    # Check if a book can be requested
    # Returns a Result with status, message, and any existing records
    def check(work_id:, edition_id: nil, book_type:)
      book_type = book_type.to_s

      # Check 1: Same edition already acquired (most specific)
      if edition_id.present?
        existing = Book.find_by(open_library_edition_id: edition_id, book_type: book_type)
        if existing&.acquired?
          return Result.new(
            status: BLOCK,
            message: "This exact edition is already in your library.",
            existing_book: existing,
            existing_request: nil
          )
        end
      end

      # Check 2: Same work + type already acquired
      existing_book = Book.find_by_work_id(work_id, book_type: book_type)
      if existing_book&.acquired?
        return Result.new(
          status: BLOCK,
          message: "This #{book_type} is already in your library.",
          existing_book: existing_book,
          existing_request: nil
        )
      end

      # Check 3: Same work + type has pending/active request
      if existing_book
        active_request = existing_book.requests.active.first
        if active_request
          return Result.new(
            status: BLOCK,
            message: "This #{book_type} already has an active request.",
            existing_book: existing_book,
            existing_request: active_request
          )
        end
      end

      # Check 4: Same work exists as different type (warn only)
      other_type = book_type == "audiobook" ? "ebook" : "audiobook"
      other_book = Book.find_by_work_id(work_id, book_type: other_type)
      if other_book
        return Result.new(
          status: WARN,
          message: "This book exists as #{other_type == 'audiobook' ? 'an audiobook' : 'an ebook'}. You can still request the #{book_type}.",
          existing_book: other_book,
          existing_request: nil
        )
      end

      # Check 5: Same work has a failed/not_found request (warn, allow retry)
      if existing_book
        failed_request = existing_book.requests.where(status: [ :failed, :not_found ]).first
        if failed_request
          return Result.new(
            status: WARN,
            message: "A previous request for this #{book_type} #{failed_request.failed? ? 'failed' : 'was not found'}. You can try again.",
            existing_book: existing_book,
            existing_request: failed_request
          )
        end
      end

      # No duplicates found
      Result.new(
        status: ALLOW,
        message: nil,
        existing_book: existing_book,
        existing_request: nil
      )
    end

    # Quick check - just returns true/false for whether request is allowed
    def can_request?(work_id:, edition_id: nil, book_type:)
      result = check(work_id: work_id, edition_id: edition_id, book_type: book_type)
      !result.block?
    end

  end
end
