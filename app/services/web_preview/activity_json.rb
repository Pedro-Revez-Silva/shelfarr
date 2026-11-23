# frozen_string_literal: true

module WebPreview
  class ActivityJson
    MATCH_CHOICES = %w[existing created].freeze
    MATCHED_BOOK_ACTION = "upload.manually_matched"

    def initialize(logs)
      @logs = logs
      requests = logs.map(&:trackable).grep(Request)
      ActiveRecord::Associations::Preloader.new(records: requests, associations: :book).call
      @matched_books = Book.where(id: logs.filter_map { |log| matched_book_id(log) }).index_by(&:id)
      book_ids = logs.map(&:trackable).grep(Book).map(&:id) + @matched_books.keys
      @library_books = Book.acquired.where(id: book_ids, book_type: Consumer::LibraryScope.types(nil, graphic: true)).pluck(:id).to_set
    end

    def entries
      @logs.map { |log| entry(log) }
    end

    def self.person(user)
      { id: user.id.to_s, name: user.name.to_s, removed: user.deleted? }
    end

    private

    def entry(log)
      {
        id: log.id.to_s,
        at: log.created_at.iso8601(3),
        action: log.action,
        actor: log.user && self.class.person(log.user),
        subject: subject(log.trackable) || book(@matched_books[matched_book_id(log)]),
        details: details(log.details)
      }
    end

    def matched_book_id(log)
      return nil unless log.action == MATCHED_BOOK_ACTION && log.details.is_a?(Hash)

      log.details["book_id"].then { |id| id if id.is_a?(Integer) && id.positive? }
    end

    def subject(trackable)
      case trackable
      when Request
        { kind: "request", id: trackable.id.to_s, title: trackable.book.title.to_s } if trackable.book
      when User
        { kind: "person", **self.class.person(trackable) }
      when Book
        book(trackable)
      else
        { kind: "other", title: trackable.title.to_s } if trackable.respond_to?(:title)
      end
    end

    def book(record)
      { kind: "book", id: record.id.to_s, title: record.title.to_s, in_library: @library_books.include?(record.id) } if record
    end

    def details(stored)
      stored = stored.is_a?(Hash) ? stored : {}
      {
        via: stored["created_via"].presence_in(Request::CREATED_VIA_VALUES),
        scopes: scopes(stored["scopes"]),
        match: stored["choice"].presence_in(MATCH_CHOICES)
      }.compact
    end

    def scopes(stored)
      return nil unless stored.is_a?(Array)

      known = stored.select { |scope| scope.is_a?(String) && APIToken::AVAILABLE_SCOPES.include?(scope) }.uniq
      known.presence
    end
  end
end
