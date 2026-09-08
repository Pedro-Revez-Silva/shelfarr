# frozen_string_literal: true

# Runtime OmniAuth setup for the OIDC provider. Settings are read from
# SettingsService so issuer/client credentials can change without reboot.
class OidcOmniauthSetup
  def self.call(env)
    strategy = env["omniauth.strategy"]

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
      redirect_uri: OidcPaths.callback_uri(env)
    }
  end
end
