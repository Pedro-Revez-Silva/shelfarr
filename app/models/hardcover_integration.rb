# frozen_string_literal: true

# Instance-level switches and limits for the Hardcover discovery, reading
# list, and author features. Personal account connections live on
# HardcoverConnection; the instance API token stays in SettingsService.
module HardcoverIntegration
  OAUTH_SCOPES = %w[read:me:content read:library read:lists read:catalog].freeze
  CALLBACK_PATH = "/hardcover/connection/callback"

  module_function

  def enabled?
    SettingsService.get(:hardcover_enabled, default: true) == true
  end

  def oauth_client_id
    SettingsService.get(:hardcover_oauth_client_id).to_s.strip
  end

  def oauth_client_secret
    SettingsService.get(:hardcover_oauth_client_secret).to_s.strip
  end

  def oauth_configured?
    enabled? && oauth_client_id.present?
  end

  def confidential_client?
    oauth_client_secret.present?
  end

  def device_flow_enabled?
    oauth_configured? && SettingsService.get(:hardcover_oauth_device_flow_enabled, default: false) == true
  end

  def personal_tokens_allowed?
    enabled? && SettingsService.get(:hardcover_allow_personal_access, default: false) == true
  end

  def connection_available?
    oauth_configured? || personal_tokens_allowed?
  end

  # Hardcover matches redirect URIs exactly, so admins can pin the public URL
  # when Shelfarr runs behind a proxy that does not forward its scheme/host.
  def redirect_uri(base_url)
    configured = SettingsService.get(:hardcover_oauth_redirect_uri).to_s.strip
    configured.presence || "#{base_url.to_s.chomp('/')}#{CALLBACK_PATH}"
  end

  def redirect_uri_acceptable?(uri)
    parsed = URI.parse(uri.to_s)
    return true if parsed.scheme == "https" && parsed.host.present?

    parsed.scheme == "http" && %w[localhost 127.0.0.1 [::1] ::1].include?(parsed.host)
  rescue URI::InvalidURIError
    false
  end

  def max_automatic_requests_per_run
    SettingsService.get(:hardcover_max_requests_per_run, default: 10).to_i.clamp(1, 100)
  end

  # A duration in seconds from `config.x.<key>`, or `default` when it is not
  # set. An unset custom key reads as an empty ActiveSupport::OrderedOptions,
  # not nil, so only a number counts as configured.
  def configured_seconds(key, default)
    value = Rails.configuration.x.public_send(key)
    value.is_a?(Numeric) ? [ value.to_f, 0.0 ].max : default
  end

  # Time between automatic checks of a subscription. The automatic request limit applies to windows of the same length.
  def sync_interval
    SettingsService.get(:hardcover_sync_interval_hours, default: 6).to_i.clamp(1, 168).hours
  end

  def personal_token_url
    "https://hardcover.app/account/api/keys/new?scope=#{OAUTH_SCOPES.join('+')}"
  end
end
