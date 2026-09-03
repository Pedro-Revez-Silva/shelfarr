require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Shelfarr
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
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
      # Invalid timezone identifier, fall back to UTC
      warn "Warning: Invalid TZ environment variable '#{tz_value}'. Falling back to UTC."
      config.time_zone = "UTC"
    end

    # Covers and store links are supplied by external catalog providers. Avoid
    # disclosing a self-hosted Shelfarr URL while retaining the origin for
    # same-origin form submissions such as the OIDC handoff.
    config.action_dispatch.default_headers["Referrer-Policy"] = "same-origin"

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
