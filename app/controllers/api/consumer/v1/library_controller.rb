# frozen_string_literal: true

class API::Consumer::V1::LibraryController < API::Consumer::V1::BaseController
  include ActionController::DataStreaming
  include ConsumerMediaResponse
  before_action -> { consumer_scope("library:read") }

  def index
    result = Consumer::Catalog.new(user: Current.user).call(query: params[:q] || "", type: params[:type], cursor: params[:cursor], limit: params[:limit])
    progress = Current.user.consumer_progresses.where(book_id: result.books.map(&:id)).index_by(&:book_id)
    render json: { items: result.books.map { |book| Consumer::Publication.new(book, user: Current.user, routes: self, progress: progress[book.id]).representation }, next_cursor: result.next_cursor }
  rescue Consumer::Catalog::Invalid => error
    render json: { error: "invalid_request", message: error.message }, status: :bad_request
  end

  def show
    render json: Consumer::Publication.new(consumer_book, user: Current.user, routes: self).representation
  end

  def asset
    serve_consumer_asset(consumer_book, params[:asset_id])
  end
end
