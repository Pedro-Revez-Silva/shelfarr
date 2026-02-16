require "digest"

class API::V1::ApplicationController < ActionController::API
  before_action :authenticate!

  rescue_from ActionDispatch::Http::Parameters::ParseError, with: :handle_parse_error

  private

  def authenticate!
    scheme, token = request.authorization.to_s.split(" ", 2)
    return unauthorized! unless scheme&.casecmp("Bearer")&.zero?
    return unauthorized! if token.blank?

    expected_token = SettingsService.api_token
    return unauthorized! if expected_token.blank?

    token_digest = Digest::SHA256.hexdigest(token)
    expected_digest = Digest::SHA256.hexdigest(expected_token)

    return if ActiveSupport::SecurityUtils.secure_compare(token_digest, expected_digest)

    unauthorized!
  end

  def handle_parse_error
    render json: { errors: [ "JSON invalid" ] }, status: :bad_request
  end

  def unauthorized!
    head :unauthorized
  end
end
