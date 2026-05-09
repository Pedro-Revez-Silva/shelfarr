require "digest"

class API::V1::ApplicationController < ActionController::API
  before_action :authenticate!

  rescue_from ActionDispatch::Http::Parameters::ParseError, with: :handle_parse_error

  private

  def require_scope!(scope)
    return if Current.api_scope?(scope)

    render json: { errors: [ "Missing API scope: #{scope}" ] }, status: :forbidden
  end

  def authenticate!
    scheme, token = request.authorization.to_s.split(" ", 2)
    return unauthorized! unless scheme&.casecmp("Bearer")&.zero?
    return unauthorized! if token.blank?

    api_token = APIToken.authenticate(token)
    if api_token
      Current.api_token = api_token
      Current.api_user = api_token.user
      return
    end

    expected_token = SettingsService.api_token
    return unauthorized! if expected_token.blank?

    token_digest = Digest::SHA256.hexdigest(token)
    expected_digest = Digest::SHA256.hexdigest(expected_token)

    if ActiveSupport::SecurityUtils.secure_compare(token_digest, expected_digest)
      Current.legacy_api_token_authenticated = true
      return
    end

    unauthorized!
  end

  def handle_parse_error
    render json: { errors: [ "JSON invalid" ] }, status: :bad_request
  end

  def unauthorized!
    head :unauthorized
  end
end
