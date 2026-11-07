# frozen_string_literal: true

require_relative "../../lib/consumer_body_limit"
Rails.application.config.middleware.insert_before Rails::Rack::Logger, ConsumerBodyLimit
