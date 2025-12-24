# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.img_src     :self, :data, "https://covers.openlibrary.org"
    policy.object_src  :none
    policy.script_src  :self
    policy.style_src   :self, :unsafe_inline  # Required for Tailwind and inline SVG styles
    policy.frame_ancestors :none
    policy.base_uri    :self
    policy.form_action :self

    # Connect sources for Turbo/Stimulus and API calls
    policy.connect_src :self

    # Upgrade insecure requests in production
    policy.upgrade_insecure_requests true if Rails.env.production?
  end

  # Generate session nonces for permitted importmap and inline scripts.
  # Note: Nonces provide additional security for inline scripts
  config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]

  # Report violations without enforcing the policy in development
  # config.content_security_policy_report_only = true
end
