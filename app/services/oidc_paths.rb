# frozen_string_literal: true

# Builds OmniAuth OIDC request and callback URLs that honor the app's
# relative URL root (RAILS_RELATIVE_URL_ROOT / Rack SCRIPT_NAME).
class OidcPaths
  REQUEST_PATH = "/auth/oidc"
  CALLBACK_PATH = "/auth/oidc/callback"

  class << self
    def request_path(script_name: nil, relative_url_root: Rails.application.config.relative_url_root)
      "#{url_prefix(script_name:, relative_url_root:)}#{REQUEST_PATH}"
    end

    def callback_path(script_name: nil, relative_url_root: Rails.application.config.relative_url_root)
      "#{url_prefix(script_name:, relative_url_root:)}#{CALLBACK_PATH}"
    end

    def callback_uri(env)
      "#{env['rack.url_scheme']}://#{env['HTTP_HOST']}#{callback_path(script_name: env['SCRIPT_NAME'])}"
    end

    def url_prefix(script_name: nil, relative_url_root: Rails.application.config.relative_url_root)
      script = normalize_prefix(script_name)
      return script if script.present?

      normalize_prefix(relative_url_root)
    end

    private

    def normalize_prefix(value)
      prefix = value.to_s.strip
      return "" if prefix.blank? || prefix == "/"

      "/#{prefix.delete_prefix('/').delete_suffix('/')}"
    end
  end
end
