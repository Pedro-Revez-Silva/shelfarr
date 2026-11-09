# frozen_string_literal: true

class API::Consumer::V1::LibraryController < API::Consumer::V1::BaseController
  include ActionController::DataStreaming
  include ConsumerMediaResponse
  before_action -> { consumer_scope("library:read") }

  rescue_from Consumer::ReaderFormats::Invalid, with: ->(error) { render json: { error: "invalid_request", message: error.message }, status: :bad_request }

  def index
    result = Consumer::Catalog.new(user: Current.user, reader_formats: reader_formats).call(query: params[:q] || "", type: params[:type], cursor: params[:cursor], limit: params[:limit], status: params[:status], sort: params[:sort])
    publications = Consumer::Publication.many(result.books, user: Current.user, routes: self, reader_formats: reader_formats)
    render json: { items: publications.values, next_cursor: result.next_cursor }
  rescue Consumer::Catalog::Invalid => error
    render json: { error: "invalid_request", message: error.message }, status: :bad_request
  end

  def continue
    render json: { items: Consumer::ContinueReading.new(user: Current.user, routes: self, reader_formats: reader_formats).call(limit: params[:limit]).values }
  end

  def show
    formats = reader_formats
    render json: Consumer::Publication.new(consumer_book(graphic: formats.graphic?), user: Current.user, routes: self, reader_formats: formats).representation
  end

  def asset
    serve_consumer_asset(consumer_book, params[:asset_id])
  end

  # The CBZ page order of this exact asset generation, from its ZIP directory.
  def reading_order
    render json: consumer_reading_order(consumer_book, params[:asset_id])
  rescue Consumer::LibraryAssets::Unavailable
    render json: { error: "asset_unavailable" }, status: :gone
  end

  # Mints a grant that fetches only this asset generation, with GET or HEAD,
  # from a transfer that must not hold the bearer.
  def transfer_grant
    book = consumer_book
    asset, file = Consumer::LibraryAssets.new(book, formats: Consumer::ReaderFormats::SUPPORTED).open(params[:asset_id])
    file.close
    grant, expires_at = Consumer::TransferGrant.issue(api_token: Current.api_token, book: book, asset_id: asset.id)
    render json: { url: api_consumer_v1_asset_transfer_path(book, asset.id, grant: grant), expires_at: expires_at.utc.iso8601 }, status: :created
  rescue Consumer::LibraryAssets::Unavailable
    render json: { error: "asset_unavailable" }, status: :gone
  end
end
