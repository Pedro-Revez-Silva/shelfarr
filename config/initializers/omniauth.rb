# frozen_string_literal: true

# OmniAuth configuration for OIDC/SSO authentication
# Settings are loaded dynamically from the database via SettingsService

Rails.application.config.middleware.use OmniAuth::Builder do
  # Configure OIDC provider with dynamic settings
  # The setup phase allows us to read settings from the database at runtime
  provider :openid_connect, {
    name: :oidc,
    setup: lambda { |env|
      strategy = env["omniauth.strategy"]

      # Skip if OIDC not configured
      unless SettingsService.oidc_configured?
        strategy.options[:issuer] = "https://invalid.example.com"
        strategy.options[:client_options] = {
          identifier: "invalid",
          secret: "invalid"
        }
        return
      end

      issuer = SettingsService.get(:oidc_issuer).to_s.strip
      client_id = SettingsService.get(:oidc_client_id).to_s.strip
      client_secret = SettingsService.get(:oidc_client_secret).to_s.strip
      scopes = SettingsService.get(:oidc_scopes).to_s.strip.split(/\s+/)

      strategy.options[:issuer] = issuer
      strategy.options[:scope] = scopes
      strategy.options[:response_type] = :code
      strategy.options[:discovery] = true
      strategy.options[:client_options] = {
        identifier: client_id,
        secret: client_secret,
        redirect_uri: "#{env['rack.url_scheme']}://#{env['HTTP_HOST']}/auth/oidc/callback"
      }
    }
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
