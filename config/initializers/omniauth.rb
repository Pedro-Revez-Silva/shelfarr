# frozen_string_literal: true

# OIDC client settings are loaded from the database during the request-time setup phase.
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :openid_connect, {
    name: :oidc,
    setup: ->(env) { OidcOmniauthSetup.call(env) }
  }
end

# Silence OmniAuth "authenticity error" for API-style callbacks
OmniAuth.config.silence_get_warning = true

OmniAuth.config.path_prefix = "/auth"

OmniAuth.config.on_failure = Proc.new { |env|
  OmniAuth::FailureEndpoint.new(env).redirect_to_failure
}
