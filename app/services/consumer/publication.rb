# frozen_string_literal: true

# One publication as consumer clients see it. Only the reading formats the
# caller declared are serialized (EPUB by default). Comic records keep their
# database type but are presented as `book_type: "ebook"`: installed readers
# know only ebook and audiobook. Clients that declare formats also receive
# `content_kind` ("book" or "graphic").
class Consumer::Publication
  def self.many(books, user:, routes:, reader_formats: Consumer::ReaderFormats::LEGACY)
    ids = books.map(&:id)
    progress = user.consumer_progresses.where(book_id: ids).index_by(&:book_id)
    states = user.consumer_reading_states.where(book_id: ids).index_by(&:book_id)
    books.index_with do |book|
      new(book, user: user, routes: routes, reader_formats: reader_formats, progress: progress[book.id], reading_state: states[book.id]).representation
    end
  end

  def initialize(book, user:, routes:, reader_formats: Consumer::ReaderFormats::LEGACY,
    progress: user.consumer_progresses.find_by(book: book), reading_state: user.consumer_reading_states.find_by(book: book))
    @book = book
    @routes = routes
    @reader_formats = reader_formats
    @progress = progress
    @reading_state = reading_state
  end

  def representation
    represent(Consumer::LibraryAssets.new(@book, formats: @reader_formats.formats).list)
  rescue Consumer::LibraryAssets::Unavailable
    represent([])
  end

  private

  def represent(assets)
    cover = safe_cover
    value = { id: @book.id.to_s, title: @book.title, author: @book.author, description: @book.description.to_s.first(20_000),
      book_type: @book.audiobook? ? "audiobook" : "ebook" }
    value[:content_kind] = graphic? ? "graphic" : "book" if @reader_formats.declared
    value.merge(cover_url: RemoteResult.failed?(cover) ? nil : cover,
      assets: assets.map { |asset| asset_representation(asset) },
      progress: @progress&.representation, reading_status: @reading_state&.status || (@progress ? "in_progress" : "unread"))
  end

  def asset_representation(asset)
    value = { id: asset.id, filename: asset.filename, format: asset.format, media_type: asset.media_type,
      size_bytes: asset.size_bytes, position: asset.position, content_url: @routes.api_consumer_v1_asset_path(@book, asset.id) }
    return value unless asset.format == "cbz"

    value.merge(page_count: asset.page_count, reading_order_url: @routes.api_consumer_v1_asset_reading_order_path(@book, asset.id))
  end

  # The comic type and the graphic content kind must never disagree on the wire.
  def graphic?
    !@book.audiobook? && (@book.comicbook? || @book.content_graphic?)
  end

  def safe_cover
    uri = URI.parse(@book.cover_url.to_s)
    uri.to_s if uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?
  rescue URI::InvalidURIError => error
    RemoteResult::Failed.new(error)
  end
end
