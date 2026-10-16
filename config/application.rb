require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

Bundler.require(*Rails.groups)

module Shelfarr
  class Application < Rails::Application
    config.load_defaults 8.1

    # Support running the app at a sub-path (e.g., /shelfarr)
    # Set RAILS_RELATIVE_URL_ROOT environment variable to configure
    config.relative_url_root = ENV.fetch("RAILS_RELATIVE_URL_ROOT", "/")

    # Keep Rails-rendered timestamps aligned with the container's time zone.
    # Active Record continues to store timestamps in UTC.
    # Validate TZ before applying to avoid initialization failures
    tz_value = ENV.fetch("TZ", "UTC")
    begin
      Time.find_zone!(tz_value) if tz_value != "UTC"
      config.time_zone = tz_value
    rescue ArgumentError
      warn "Warning: Invalid TZ environment variable '#{tz_value}'. Falling back to UTC."
      config.time_zone = "UTC"
    end

    # same-origin Referrer-Policy: cover links must not leak the self-hosted URL; OIDC form posts still send an origin.
    config.action_dispatch.default_headers["Referrer-Policy"] = "same-origin"

    config.autoload_lib(ignore: %w[assets tasks])
  end
end
