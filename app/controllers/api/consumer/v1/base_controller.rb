# frozen_string_literal: true

class API::Consumer::V1::BaseController < ActionController::API
  before_action :authenticate_consumer
  rescue_from ActionDispatch::Http::Parameters::ParseError, with: -> { render json: { error: "invalid_json" }, status: :bad_request }

  private

  def authenticate_consumer
    headers["Cache-Control"] = "private, no-store"
    headers["Referrer-Policy"] = "no-referrer"
    scheme, raw = request.authorization.to_s.split(" ", 2)
    token = APIToken.authenticate(raw) if scheme&.casecmp("Bearer")&.zero?
    return head :unauthorized unless token&.user && !token.user.deleted?

    Current.api_token = token
    Current.api_user = token.user
  end

  def consumer_scope(scope)
    return if Current.api_token.has_scope?(scope)

    render json: { error: "insufficient_scope", required_scope: scope }, status: :forbidden
  end

  # Comic records are reachable by ID for media, progress and status: only a
  # client that declared a fixed-layout format can have learned one. Listing
  # them (graphic: false) follows the caller's declared formats.
  def consumer_book(graphic: true)
    id = params[:id]
    raise ActiveRecord::RecordNotFound unless id.is_a?(String) && id.match?(/\A[1-9]\d{0,18}\z/)

    Book.acquired.where(book_type: Consumer::LibraryScope.types(nil, graphic: graphic)).find(id)
  end

  def reader_formats
    response.headers["Vary"] = [ response.headers["Vary"], Consumer::ReaderFormats::HEADER ].compact_blank.join(", ")
    @reader_formats ||= Consumer::ReaderFormats.from(request)
  end
end
