# frozen_string_literal: true

require_relative "../../lib/kobo_body_limit"
Rails.application.config.middleware.insert_before Rails::Rack::Logger, KoboBodyLimit
