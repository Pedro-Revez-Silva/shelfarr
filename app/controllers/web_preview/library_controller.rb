# frozen_string_literal: true

class WebPreview::LibraryController < WebPreview::APIController
  include ConsumerWebPublication

  rescue_from Consumer::Catalog::Invalid, with: ->(error) { render_error("invalid_request", :bad_request, message: error.message) }

  def index
    result = Consumer::Catalog.new(user: Current.user, reader_formats: web_reader_formats)
      .call(query: params[:q] || "", type: params[:type], cursor: params[:cursor], limit: params[:limit] || "30", status: params[:status], sort: params[:sort])
    publications = Consumer::Publication.many(result.books, user: Current.user, routes: self, reader_formats: web_reader_formats)
    render json: { account: web_preview_account_id, items: result.books.map { |book| summary(book, publications.fetch(book)) }, next_cursor: result.next_cursor }
  end

  def continue
    reading = Consumer::ContinueReading.new(user: Current.user, routes: self, reader_formats: web_reader_formats).call(limit: 3, type: params[:type])
    render json: { account: web_preview_account_id, items: reading.map { |book, publication| summary(book, publication) } }
  end

  def show
    book = web_book(params[:id])
    render json: { account: web_preview_account_id, publication: detail(book) }
  end

  def reading_status
    book = web_book(params[:id])
    Consumer::ReadingStatus.set(user: Current.user, book: book, status: params[:status])
    render json: { account: web_preview_account_id, publication: detail(book) }
  rescue Consumer::ReadingStatus::Invalid => error
    render_error("invalid_reading_status", :unprocessable_entity, message: error.message)
  end

  private

  def summary(book, representation)
    json_for(book, representation).summary
  end

  def detail(book)
    json_for(book, Consumer::Publication.new(book, user: Current.user, routes: self, reader_formats: web_reader_formats).representation).detail
  end

  def json_for(book, representation)
    WebPreview::PublicationJson.new(book: book, representation: representation, reader_path: consumer_publication_path(book),
      progress_label: helpers.consumer_progress_label(representation), format_label: helpers.consumer_format_label(book, representation),
      cover_style: helpers.consumer_cover_style(book))
  end
end
