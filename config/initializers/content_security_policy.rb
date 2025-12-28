# frozen_string_literal: true

# Content Security Policy is DISABLED by default for self-hosted setups.
#
# Shelfarr is designed to run on home networks like Radarr, Sonarr, and Jellyfin.
# Strict CSP policies cause issues with:
# - HTTP access on local networks
# - External image sources (Open Library covers redirect through multiple domains)
# - Reverse proxy setups
#
# If you're exposing Shelfarr to the internet and want additional security,
# you can uncomment and customize the policy below. However, the recommended
# approach is to use a reverse proxy (nginx, Caddy, Traefik) with SSL termination.

# Rails.application.configure do
#   config.content_security_policy do |policy|
#     policy.default_src :self
#     policy.font_src    :self, :data
#     policy.img_src     :self, :data, :https
#     policy.object_src  :none
#     policy.script_src  :self, :unsafe_inline
#     policy.style_src   :self, :unsafe_inline
#     policy.frame_ancestors :none
#   end
# end
