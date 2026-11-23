# frozen_string_literal: true

class WebPreview::ReaderController < WebPreview::APIController
  include ConsumerMediaResponse
  include ConsumerWebPublication

  prepend_before_action :refuse_cross_site_fetch, only: :reading_order

  def show
    book = web_book(params[:id])
    representation = Consumer::Publication.new(book, user: Current.user, routes: self, reader_formats: web_reader_formats, read_along: true).representation
    render json: { account: web_preview_account_id, publication: reader_publication(book, representation) }
  end

  def progress
    book = web_book(params[:id])
    render json: { account: web_preview_account_id, progress: Current.user.consumer_progresses.find_by(book: book)&.representation }
  end

  def save_progress
    result = Consumer::ProgressWriter.new(user: Current.user, book: web_book(params[:id])).call(Consumer::ProgressWriter.attributes(params))
    render json: { account: web_preview_account_id, progress: result.representation }
  rescue Consumer::ProgressWriter::Invalid, Consumer::LibraryAssets::Unavailable => error
    render_error("invalid_progress", :unprocessable_entity, message: error.message)
  rescue Consumer::ProgressWriter::Conflict => error
    render json: { account: web_preview_account_id, error: "progress_conflict", progress: error.progress&.representation }, status: :conflict
  end

  def reading_order
    render json: { account: web_preview_account_id, **consumer_reading_order(web_book(params[:id]), params[:asset_id]) }
  rescue Consumer::LibraryAssets::Unavailable
    render_error("asset_unavailable", :gone)
  end

  private

  def reader_publication(book, representation)
    assets = representation.fetch(:assets)
    { id: book.id.to_s, title: book.title.to_s, author: book.author.presence, book_type: representation.fetch(:book_type),
      content_kind: representation.fetch(:content_kind), reading_status: representation.fetch(:reading_status),
      assets: assets.map { |asset| reader_asset(book, asset) }, other_formats: [], progress: representation[:progress],
      classic_reader: { url: consumer_publication_path(book), read_along: assets.any? { |asset| asset.dig(:read_along, :status) == "available" } } }
  end

  def reader_asset(book, asset)
    value = asset.slice(:id, :filename, :format, :media_type, :size_bytes, :position)
      .merge(url: web_preview_api_media_path(account: web_preview_account_id, id: book.id, asset_id: asset.fetch(:id)))
    return value unless asset.fetch(:format) == "cbz"

    value.merge(page_count: asset[:page_count], reading_order_url: web_preview_api_reading_order_path(id: book.id, asset_id: asset.fetch(:id))).compact
  end
end
