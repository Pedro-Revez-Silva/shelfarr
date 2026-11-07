# frozen_string_literal: true

class Consumer::Publication
  def initialize(book, user:, routes:, progress: user.consumer_progresses.find_by(book: book))
    @book = book
    @routes = routes
    @progress = progress
  end

  def representation
    assets = Consumer::LibraryAssets.new(@book).list
    represent(assets)
  rescue Consumer::LibraryAssets::Unavailable
    represent([])
  end

  private

  def represent(assets)
    cover = safe_cover
    { id: @book.id.to_s, title: @book.title, author: @book.author, description: @book.description.to_s.first(20_000),
      book_type: @book.book_type, cover_url: RemoteResult.failed?(cover) ? nil : cover,
      assets: assets.map { |asset| { id: asset.id, filename: asset.filename,
        format: asset.format, media_type: asset.media_type, size_bytes: asset.size_bytes,
        position: asset.position, content_url: @routes.api_consumer_v1_asset_path(@book, asset.id) } },
      progress: @progress&.representation }
  end

  def safe_cover
    uri = URI.parse(@book.cover_url.to_s)
    uri.to_s if uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?
  rescue URI::InvalidURIError => error
    RemoteResult::Failed.new(error)
  end
end
