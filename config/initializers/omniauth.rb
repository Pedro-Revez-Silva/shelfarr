# frozen_string_literal: true

# OmniAuth configuration for OIDC/SSO authentication
# Settings are loaded dynamically from the database via SettingsService

Rails.application.config.middleware.use OmniAuth::Builder do
  # Configure OIDC provider with dynamic settings
  # The setup phase allows us to read settings from the database at runtime
  provider :openid_connect, {
    name: :oidc,
    setup: ->(env) { OidcOmniauthSetup.call(env) }
  }
end

# Silence OmniAuth "authenticity error" for API-style callbacks
OmniAuth.config.silence_get_warning = true

# Set path prefix for auth routes
OmniAuth.config.path_prefix = "/auth"

# Handle failures
OmniAuth.config.on_failure = Proc.new { |env|
  OmniAuth::FailureEndpoint.new(env).redirect_to_failure
}
