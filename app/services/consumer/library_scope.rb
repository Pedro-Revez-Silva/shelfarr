# frozen_string_literal: true

class Consumer::LibraryScope
  STATUS_SQL = "CASE WHEN crs.status = 2 THEN 'finished' WHEN crs.status = 1 THEN 'in_progress' WHEN crs.status = 0 THEN 'unread' WHEN cp.id IS NOT NULL THEN 'in_progress' ELSE 'unread' END".freeze
  ACTIVITY_SQL = "CASE WHEN cp.updated_at IS NULL THEN crs.updated_at WHEN crs.updated_at > cp.updated_at THEN crs.updated_at ELSE cp.updated_at END".freeze

  def self.for(user)
    Book.acquired.where(book_type: %w[ebook audiobook])
      .joins(Book.sanitize_sql_array([ "LEFT JOIN consumer_progresses cp ON cp.book_id = books.id AND cp.user_id = ?", user.id ]))
      .joins(Book.sanitize_sql_array([ "LEFT JOIN consumer_reading_states crs ON crs.book_id = books.id AND crs.user_id = ?", user.id ]))
      .select("books.*")
  end
end
