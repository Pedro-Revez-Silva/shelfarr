# frozen_string_literal: true

module WebPreview
  class ActivityJson
    MATCH_CHOICES = %w[existing created].freeze

    def initialize(logs)
      @logs = logs
      requests = logs.map(&:trackable).grep(Request)
      ActiveRecord::Associations::Preloader.new(records: requests, associations: :book).call
      books = logs.map(&:trackable).grep(Book)
      @library_books = Book.acquired.where(id: books.map(&:id), book_type: Consumer::LibraryScope.types(nil, graphic: true)).pluck(:id).to_set
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
        subject: subject(log.trackable),
        details: details(log.details)
      }
    end

    def subject(trackable)
      case trackable
      when Request
        { kind: "request", id: trackable.id.to_s, title: trackable.book.title.to_s } if trackable.book
      when User
        { kind: "person", **self.class.person(trackable) }
      when Book
        { kind: "book", id: trackable.id.to_s, title: trackable.title.to_s, in_library: @library_books.include?(trackable.id) }
      else
        { kind: "other", title: trackable.title.to_s } if trackable.respond_to?(:title)
      end
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
