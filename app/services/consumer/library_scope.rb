# frozen_string_literal: true

class Consumer::LibraryScope
  STATUS_SQL = "CASE WHEN crs.status = 2 THEN 'finished' WHEN crs.status = 1 THEN 'in_progress' WHEN crs.status = 0 THEN 'unread' WHEN cp.id IS NOT NULL THEN 'in_progress' ELSE 'unread' END".freeze
  # A saved place's activity is when it was observed. Rows with an unknown
  # observation time fall back to server receipt only for ordering.
  PROGRESS_ACTIVITY_SQL = "COALESCE(cp.observed_at, cp.updated_at)".freeze
  ACTIVITY_SQL = "CASE WHEN cp.id IS NULL THEN crs.updated_at WHEN crs.updated_at > #{PROGRESS_ACTIVITY_SQL} THEN crs.updated_at ELSE #{PROGRESS_ACTIVITY_SQL} END".freeze

  def self.for(user)
    Book.acquired.where(book_type: %w[ebook audiobook])
      .joins(Book.sanitize_sql_array([ "LEFT JOIN consumer_progresses cp ON cp.book_id = books.id AND cp.user_id = ?", user.id ]))
      .joins(Book.sanitize_sql_array([ "LEFT JOIN consumer_reading_states crs ON crs.book_id = books.id AND crs.user_id = ?", user.id ]))
      .select("books.*")
  end
end
