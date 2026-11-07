# frozen_string_literal: true

class API::Consumer::V1::LibraryController < API::Consumer::V1::BaseController
  include ActionController::DataStreaming
  include ConsumerMediaResponse
  before_action -> { consumer_scope("library:read") }

  def index
    result = Consumer::Catalog.new(user: Current.user).call(query: params[:q] || "", type: params[:type], cursor: params[:cursor], limit: params[:limit], status: params[:status], sort: params[:sort])
    publications = Consumer::Publication.many(result.books, user: Current.user, routes: self)
    render json: { items: publications.values, next_cursor: result.next_cursor }
  rescue Consumer::Catalog::Invalid => error
    render json: { error: "invalid_request", message: error.message }, status: :bad_request
  end

  def continue
    render json: { items: Consumer::ContinueReading.new(user: Current.user, routes: self).call(limit: params[:limit]).values }
  end

  def show
    render json: Consumer::Publication.new(consumer_book, user: Current.user, routes: self).representation
  end

  def asset
    serve_consumer_asset(consumer_book, params[:asset_id])
  end
end
