class API::V1::ApplicationController < ActionController::API
  before_action :authenticate!

  rescue_from ActionDispatch::Http::Parameters::ParseError, with: :handle_parse_error

  private

  def authenticate!
    token = request.headers["Authorization"]&.remove("Bearer ")

    return head :unauthorized if token.blank?
    return head :unauthorized unless SettingsService.api_token_configured?

    head :unauthorized unless SettingsService.get(:api_token) == token
  end

  def handle_parse_error
    render json: { errors: [ "JSON invalid" ] }, status: :bad_request
  end
end
