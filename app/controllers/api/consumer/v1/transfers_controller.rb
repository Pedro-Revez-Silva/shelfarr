# frozen_string_literal: true

# Asset bytes for a transfer grant instead of the account bearer. Only this
# route reads grants, and it reads nothing else: no Authorization header, no
# cookies. Responses are never redirects.
class API::Consumer::V1::TransfersController < API::Consumer::V1::BaseController
  include ActionController::DataStreaming
  include ConsumerMediaResponse

  # One literal `grant` parameter and nothing else, so no encoded, repeated or
  # nested spelling can stand in for it.
  QUERY = /\Agrant=([^&;=]+)\z/

  skip_before_action :authenticate_consumer
  before_action :authenticate_grant
  rescue_from ActiveRecord::RecordNotFound, with: -> { render json: { error: "not_found" }, status: :not_found }

  def show
    serve_consumer_asset(consumer_book, params[:asset_id])
  end

  private

  def authenticate_grant
    headers["Cache-Control"] = "private, no-store"
    headers["Referrer-Policy"] = "no-referrer"
    grant = QUERY.match(request.query_string)&.captures&.first
    return if grant && Consumer::TransferGrant.verify(grant, book_id: params[:id], asset_id: params[:asset_id])

    render json: { error: "invalid_grant" }, status: :unauthorized
  end
end
