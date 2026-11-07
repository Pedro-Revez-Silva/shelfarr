# frozen_string_literal: true

require_relative "../../lib/consumer_grant_query_guard"
Rails.application.config.middleware.insert_before Rails::Rack::Logger, ConsumerGrantQueryGuard
