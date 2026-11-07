# frozen_string_literal: true

class Consumer::Catalog
  class Invalid < StandardError; end
  Result = Data.define(:books, :next_cursor)
  TITLE_SORT = "LOWER(COALESCE(books.title, ''))".freeze

  def initialize(user:)
    @user = user
  end

  def call(query:, type:, cursor:, limit:, status: nil, sort: nil)
    raise Invalid, "Unknown publication type" unless type.blank? || %w[ebook audiobook].include?(type)
    raise Invalid, "Search is too long" unless query.is_a?(String) && query.bytesize <= 200
    raise Invalid, "Unknown reading status" unless status.blank? || ConsumerReadingState.statuses.key?(status)
    sort = sort.presence || "recent"
    raise Invalid, "Unknown library sort" unless %w[recent title].include?(sort)

    limit = limit.is_a?(String) && limit.match?(/\A\d{1,3}\z/) ? limit.to_i.clamp(1, 50) : 30
    key = Digest::SHA256.hexdigest([ @user.id, query, type, status, sort ].join("\0"))
    before = decode_cursor(cursor, key, sort)
    relation = Consumer::LibraryScope.for(@user)
    relation = relation.where(book_type: type) if type.present?
    relation = relation.where("#{Consumer::LibraryScope::STATUS_SQL} = ?", status) if status.present?
    if query.present?
      escaped = "%#{Book.sanitize_sql_like(query)}%"
      relation = relation.where("books.title LIKE :query ESCAPE '\\' OR books.author LIKE :query ESCAPE '\\'", query: escaped)
    end
    if sort == "title"
      relation = relation.select("#{TITLE_SORT} AS consumer_title_sort")
      relation = relation.where("#{TITLE_SORT} > ? OR (#{TITLE_SORT} = ? AND books.id > ?)", before[0], before[0], before[1]) if before
      relation = relation.order(Arel.sql("#{TITLE_SORT} ASC"), id: :asc)
    else
      relation = relation.where("books.id < ?", before) if before
      relation = relation.order(id: :desc)
    end
    books = relation.limit(limit + 1).to_a
    more = books.size > limit
    books = books.first(limit)
    next_cursor = if more
      boundary = sort == "title" ? [ books.last[:consumer_title_sort], books.last.id ] : books.last.id
      verifier.generate({ "key" => key, "before" => boundary }, purpose: "consumer-library")
    end
    Result.new(books: books, next_cursor: next_cursor)
  end

  private

  def decode_cursor(cursor, key, sort)
    return if cursor.blank?

    value = verifier.verified(cursor.to_s, purpose: "consumer-library") if cursor.is_a?(String) && cursor.bytesize <= 4096
    boundary = value["before"] if value.is_a?(Hash) && value["key"] == key
    valid = sort == "title" ? boundary.is_a?(Array) && boundary.size == 2 && boundary[0].is_a?(String) && boundary[1].is_a?(Integer) && boundary[1].positive? : boundary.is_a?(Integer) && boundary.positive?
    raise Invalid, "Invalid library cursor" unless valid

    boundary
  end

  def verifier
    Rails.application.message_verifier("consumer-catalog-v1")
  end
end
