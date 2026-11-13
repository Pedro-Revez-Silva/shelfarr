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

# OIDC callbacks use the request host, including X-Forwarded-Host, because a
# self-hosted install has no single public hostname. When the operator lists
# the hostnames registered with the identity provider, reject every other host
# before that callback URL is sent. An empty list would reject every login.
Rails.application.config.to_prepare do
  allowed_hosts = OidcOmniauthSetup.allowed_hosts
  OmniAuth.config.allowed_hosts = allowed_hosts if allowed_hosts.any?
end

OmniAuth.config.path_prefix = "/auth"

OmniAuth.config.on_failure = Proc.new { |env|
  OmniAuth::FailureEndpoint.new(env).redirect_to_failure
}
