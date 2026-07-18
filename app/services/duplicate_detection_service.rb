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
    def check(work_id:, edition_id: nil, book_type:, source_work_ids: nil, existing_books_lookup: nil)
      book_type = book_type.to_s
      work_ids = [ work_id, *Array(source_work_ids) ].compact_blank.uniq

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
      existing_book = find_existing_book(work_ids, book_type: book_type, existing_books_lookup: existing_books_lookup)
      if existing_book&.acquired?
        return Result.new(
          status: BLOCK,
          message: "This #{label_for(book_type)} is already in your library.",
          existing_book: existing_book,
          existing_request: nil
        )
      end

      # Check 3: Same work + type has pending/active request
      if existing_book
        active_request = existing_book.requests.open.first
        if active_request
          return Result.new(
            status: BLOCK,
            message: "This #{label_for(book_type)} already has an active request.",
            existing_book: existing_book,
            existing_request: active_request
          )
        end
      end

      # Check 4: Same work exists as different type (warn only)
      other_books = (Book.book_types.keys - [ book_type ]).filter_map do |other_type|
        book = find_existing_book(work_ids, book_type: other_type, existing_books_lookup: existing_books_lookup)
        [ other_type, book ] if book
      end
      if other_books.any?
        other_type, other_book = other_books.first
        return Result.new(
          status: WARN,
          message: "This title exists as #{label_with_article(other_type)}. You can still request the #{label_for(book_type)}.",
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
            message: "A previous request for this #{label_for(book_type)} #{failed_request.failed? ? 'failed' : 'was not found'}. You can try again.",
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
    def can_request?(work_id:, edition_id: nil, book_type:, source_work_ids: nil, existing_books_lookup: nil)
      result = check(
        work_id: work_id,
        edition_id: edition_id,
        book_type: book_type,
        source_work_ids: source_work_ids,
        existing_books_lookup: existing_books_lookup
      )
      !result.block?
    end

    def find_existing_book(work_ids, book_type:, existing_books_lookup: nil)
      if existing_books_lookup.present?
        Book.find_in_lookup(existing_books_lookup, work_ids, book_type: book_type)
      else
        Book.find_by_any_work_id(work_ids, book_type: book_type)
      end
    end

    def label_with_article(book_type)
      label = label_for(book_type)
      article = label.match?(/\A[aeiou]/i) ? "an" : "a"
      "#{article} #{label}"
    end

    def label_for(book_type)
      return "Comics & Manga title" if book_type.to_s == "comicbook"

      RequestOptionPolicy.book_type_label(book_type).downcase
    end
  end
end
