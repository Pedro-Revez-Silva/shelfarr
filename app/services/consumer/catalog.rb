# frozen_string_literal: true

class Consumer::Catalog
  class Invalid < StandardError; end
  Result = Data.define(:books, :next_cursor)

  def initialize(user:)
    @user = user
  end

  def call(query:, type:, cursor:, limit:)
    raise Invalid, "Unknown publication type" unless type.blank? || %w[ebook audiobook].include?(type)
    raise Invalid, "Search is too long" unless query.is_a?(String) && query.bytesize <= 200

    limit = limit.is_a?(String) && limit.match?(/\A\d{1,3}\z/) ? limit.to_i.clamp(1, 50) : 30
    key = Digest::SHA256.hexdigest([ @user.id, query, type ].join("\0"))
    before = decode_cursor(cursor, key)
    relation = Book.acquired.where(book_type: type.presence || %w[ebook audiobook])
    if query.present?
      escaped = "%#{Book.sanitize_sql_like(query)}%"
      relation = relation.where("title LIKE :query ESCAPE '\\' OR author LIKE :query ESCAPE '\\'", query: escaped)
    end
    relation = relation.where("id < ?", before) if before
    books = relation.order(id: :desc).limit(limit + 1).to_a
    more = books.size > limit
    books = books.first(limit)
    next_cursor = verifier.generate({ "key" => key, "before" => books.last.id }, purpose: "consumer-library") if more
    Result.new(books: books, next_cursor: next_cursor)
  end

  private

  def decode_cursor(cursor, key)
    return if cursor.blank?

    value = verifier.verified(cursor.to_s, purpose: "consumer-library") if cursor.is_a?(String) && cursor.bytesize <= 4096
    unless value.is_a?(Hash) && value["key"] == key && value["before"].is_a?(Integer) && value["before"].positive?
      raise Invalid, "Invalid library cursor"
    end
    value["before"]
  end

  def verifier
    Rails.application.message_verifier("consumer-catalog-v1")
  end
end
