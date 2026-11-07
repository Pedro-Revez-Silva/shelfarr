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
    grant, device_code, user_code = ConsumerDeviceGrant.issue!(client_name: name.strip)
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

  def private_response
    headers["Cache-Control"] = "private, no-store"
    headers["Referrer-Policy"] = "no-referrer"
  end
end
