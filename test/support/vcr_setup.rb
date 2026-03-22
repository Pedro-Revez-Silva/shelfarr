# frozen_string_literal: true

require "vcr"
require "webmock/minitest"

VCR.configure do |config|
  config.cassette_library_dir = "test/cassettes"
  config.hook_into :webmock
  config.ignore_localhost = true

  # Allow real HTTP connections when recording new cassettes
  config.allow_http_connections_when_no_cassette = false

  # Re-record cassettes every 30 days to keep data fresh
  config.default_cassette_options = {
    record: :new_episodes,
    re_record_interval: 30.days
  }

  # Filter sensitive data
  config.filter_sensitive_data("<PROWLARR_API_KEY>") { ENV["PROWLARR_API_KEY"] }
  config.filter_sensitive_data("<DOWNLOAD_CLIENT_PASSWORD>") { ENV["DOWNLOAD_CLIENT_PASSWORD"] }
end

# Helper module for using VCR in tests
module VCRHelper
  def with_cassette(name, options = {}, &block)
    # Tests should be deterministic by default. Opt in to re-recording
    # explicitly via options or VCR_RECORD=true when refreshing cassettes.
    default_options = ENV["VCR_RECORD"] == "true" ? {} : { record: :none }
    VCR.use_cassette(name, default_options.merge(options), &block)
  end
end
