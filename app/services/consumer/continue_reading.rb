# frozen_string_literal: true

class Consumer::ContinueReading
  def initialize(user:, routes:, reader_formats: Consumer::ReaderFormats::LEGACY)
    @user = user
    @routes = routes
    @reader_formats = reader_formats
  end

  def call(limit: 10, type: nil)
    limit = limit.to_s.match?(/\A\d{1,3}\z/) ? limit.to_i.clamp(1, 20) : 10
    base = Consumer::LibraryScope.for(@user, graphic: @reader_formats.graphic?)
    scope = base.where(id: @user.consumer_progresses.select(:book_id))
      .or(base.where(id: @user.consumer_reading_states.in_progress.select(:book_id)))
      .where("#{Consumer::LibraryScope::STATUS_SQL} = ?", "in_progress")
    scope = scope.where(book_type: Consumer::LibraryScope.types(type, graphic: @reader_formats.graphic?)) if %w[ebook audiobook].include?(type)
    books = scope.order(Arel.sql("#{Consumer::LibraryScope::ACTIVITY_SQL} DESC"), id: :desc).limit(200).to_a
    result = {}
    books.each_slice(20) do |page|
      Consumer::Publication.many(page, user: @user, routes: @routes, reader_formats: @reader_formats).each do |book, publication|
        assets = publication[:assets]
        next if assets.empty? || (publication[:progress] && assets.none? { |asset| asset[:id] == publication[:progress][:asset_id] })

        result[book] = publication
        return result if result.size >= limit
      end
    end
    result
  end
end
