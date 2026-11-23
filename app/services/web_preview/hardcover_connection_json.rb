# frozen_string_literal: true

module WebPreview
  class HardcoverConnectionJson
    PROFILE_ORIGIN = "https://hardcover.app"

    def initialize(user, sign_in:, routes:)
      @user = user
      @sign_in = sign_in
      @routes = routes
    end

    def state(outcome: nil)
      enabled = HardcoverIntegration.enabled?
      {
        enabled: enabled,
        methods: methods(enabled),
        connection: enabled ? connection_json : nil,
        device: enabled && HardcoverIntegration.device_flow_enabled? ? device_json : nil,
        outcome: outcome,
        links: links
      }
    end

    private

    def methods(enabled)
      { sign_in: enabled && HardcoverIntegration.oauth_configured?, code: enabled && HardcoverIntegration.device_flow_enabled?, api_key: enabled && HardcoverIntegration.personal_tokens_allowed? }
    end

    def connection_json
      connection = HardcoverConnection.find_by(user_id: @user.id)
      return unless connection

      {
        version: connection.version,
        username: connection.hardcover_username.to_s,
        profile_url: connection.hardcover_username.present? ? "#{PROFILE_ORIGIN}/@#{ERB::Util.url_encode(connection.hardcover_username)}" : nil,
        method: connection.oauth? ? "sign_in" : "api_key",
        state: connection.active? ? "active" : "needs_reconnecting",
        problem: connection.active? ? nil : connection.last_error.presence
      }
    end

    def device_json
      pending = @sign_in.pending_device(warm: true)
      return unless pending

      {
        user_code: pending["user_code"].to_s,
        verification_uri: pending["verification_uri"].to_s,
        verification_uri_complete: pending["verification_uri_complete"].presence,
        expires_at: Time.zone.at(pending["expires_at"].to_i).iso8601(3),
        interval: pending["interval"].to_i.clamp(5, 120)
      }
    end

    def links
      value = { following: @routes.hardcover_subscriptions_path }
      value[:api_key_page] = HardcoverIntegration.personal_token_url if HardcoverIntegration.personal_tokens_allowed?
      value
    end
  end
end
