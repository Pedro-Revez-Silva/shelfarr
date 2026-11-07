# frozen_string_literal: true

class Consumer::LibraryController < ApplicationController
  include ConsumerMediaResponse
  layout "consumer"
  before_action :private_response

  def index
    @query = params[:q] || ""
    @type = params[:type]
    @status = params[:status]
    @sort = params[:sort].presence || "recent"
    result = Consumer::Catalog.new(user: Current.user).call(query: @query, type: @type, cursor: params[:cursor], limit: "30", status: @status, sort: @sort)
    @next_cursor = result.next_cursor
    @books = result.books
    continuing = @query.blank? && params[:cursor].blank? && @status.blank? ? Consumer::ContinueReading.new(user: Current.user, routes: self).call(limit: 3, type: @type) : {}
    @continue_books = continuing.keys
    @publications = Consumer::Publication.many((@books + @continue_books).uniq(&:id), user: Current.user, routes: self).merge(continuing)
  rescue Consumer::Catalog::Invalid => error
    redirect_to consumer_library_path, alert: error.message
  end

  def show
    @book = find_book
    @publication = Consumer::Publication.new(@book, user: Current.user, routes: self).representation
    @publication[:assets].each { |asset| asset[:content_url] = consumer_asset_path(@book, asset[:id]) }
    @publication[:progress_url] = consumer_progress_path(@book)
  end

  def asset
    serve_consumer_asset(find_book, params[:asset_id])
  end

  def progress
    result = Consumer::ProgressWriter.new(user: Current.user, book: find_book).call(Consumer::ProgressWriter.attributes(params))
    render json: { progress: result.representation }
  rescue Consumer::ProgressWriter::Invalid, Consumer::LibraryAssets::Unavailable => error
    render json: { error: "invalid_progress", message: error.message }, status: :unprocessable_entity
  rescue Consumer::ProgressWriter::Conflict => error
    render json: { error: "progress_conflict", progress: error.progress&.representation }, status: :conflict
  end

  def reading_status
    book = find_book
    Consumer::ReadingStatus.set(user: Current.user, book: book, status: params[:status])
    if request.format.json?
      render json: Consumer::Publication.new(book, user: Current.user, routes: self).representation
    else
      redirect_to consumer_publication_path(book), status: :see_other, notice: "Reading status saved. Your saved place is kept."
    end
  rescue Consumer::ReadingStatus::Invalid => error
    if request.format.json?
      render json: { error: "invalid_reading_status", message: error.message }, status: :unprocessable_entity
    else
      redirect_to consumer_publication_path(book), status: :see_other, alert: error.message
    end
  end

  private

  def find_book
    id = params[:id]
    raise ActiveRecord::RecordNotFound unless id.is_a?(String) && id.match?(/\A[1-9]\d{0,18}\z/)

    Book.acquired.where(book_type: %w[ebook audiobook]).find(id)
  end

  def private_response
    headers["Cache-Control"] = "private, no-store"
  end
end
