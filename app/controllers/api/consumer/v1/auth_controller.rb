# frozen_string_literal: true

class API::Consumer::V1::AuthController < ActionController::API
  include ActionController::RateLimiting

  before_action :private_response
  rate_limit to: 20, within: 3.minutes, only: :device,
    with: -> { render json: { error: "slow_down" }, status: :too_many_requests }
  rate_limit to: 120, within: 1.minute, only: :token,
    with: -> { render json: { error: "slow_down" }, status: :too_many_requests }

  def device
    name = params[:client_name]
    unless name.is_a?(String) && name.strip.present? && name.bytesize <= 80
      return render json: { error: "invalid_request" }, status: :bad_request
    end
    replaces = upgrading_token
    return head :unauthorized if replaces == :invalid

    begin
      grant, device_code, user_code = ConsumerDeviceGrant.issue!(client_name: name.strip, scope: params[:scope], replaces: replaces)
    rescue ConsumerDeviceGrant::InvalidScope
      return render json: { error: "invalid_scope" }, status: :bad_request
    end
    render json: { device_code: device_code, user_code: user_code,
      verification_uri: consumer_connect_url,
      verification_uri_complete: consumer_connect_url(user_code: user_code),
      expires_in: ConsumerDeviceGrant::LIFETIME.to_i, interval: grant.poll_interval }
  end

  def token
    grant = ConsumerDeviceGrant.for_device_code(params[:device_code])
    result = grant ? grant.exchange! : { error: "expired_token" }
    render json: result, status: result.key?(:error) ? :bad_request : :ok
  end

  private

  # An app that is already connected sends its bearer to ask for more
  # permission on the same connection. A stale bearer is an error, not a
  # silent fallback to a fresh connection.
  def upgrading_token
    return nil if request.authorization.blank?

    scheme, raw = request.authorization.to_s.split(" ", 2)
    token = APIToken.authenticate(raw) if scheme&.casecmp("Bearer")&.zero?
    token&.user && !token.user.deleted? && token.has_scope?("library:read") ? token : :invalid
  end

  def private_response
    headers["Cache-Control"] = "private, no-store"
    headers["Referrer-Policy"] = "no-referrer"
  end
end
