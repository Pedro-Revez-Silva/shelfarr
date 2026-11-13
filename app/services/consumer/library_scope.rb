# frozen_string_literal: true

class Consumer::LibraryScope
  STATUS_SQL = "CASE WHEN crs.status = 2 THEN 'finished' WHEN crs.status = 1 THEN 'in_progress' WHEN crs.status = 0 THEN 'unread' WHEN cp.id IS NOT NULL THEN 'in_progress' ELSE 'unread' END".freeze
  # A saved place's activity is when it was observed. Rows with an unknown
  # observation time fall back to server receipt only for ordering.
  PROGRESS_ACTIVITY_SQL = "COALESCE(cp.observed_at, cp.updated_at)".freeze
  ACTIVITY_SQL = "CASE WHEN cp.id IS NULL THEN crs.updated_at WHEN crs.updated_at > #{PROGRESS_ACTIVITY_SQL} THEN crs.updated_at ELSE #{PROGRESS_ACTIVITY_SQL} END".freeze

  # Comic records appear only for callers that can open a fixed-layout format;
  # they are presented as ebooks.
  def self.for(user, graphic: false)
    Book.acquired.where(book_type: types(nil, graphic: graphic))
      .joins(Book.sanitize_sql_array([ "LEFT JOIN consumer_progresses cp ON cp.book_id = books.id AND cp.user_id = ?", user.id ]))
      .joins(Book.sanitize_sql_array([ "LEFT JOIN consumer_reading_states crs ON crs.book_id = books.id AND crs.user_id = ?", user.id ]))
      .select("books.*")
  end

  # Database types behind a consumer type filter ("ebook", "audiobook" or nil).
  def self.types(type, graphic: false)
    reading = graphic ? %w[ebook comicbook] : %w[ebook]
    case type
    when "ebook" then reading
    when "audiobook" then %w[audiobook]
    else reading + %w[audiobook]
    end
  end
end
