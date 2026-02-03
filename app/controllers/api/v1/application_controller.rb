class API::V1::ApplicationController < ActionController::API
  rescue_from ActionDispatch::Http::Parameters::ParseError, with: :handle_parse_error

  private

  def handle_parse_error
    render json: { errors: [ "JSON invalid" ] }, status: :bad_request
  end
end
