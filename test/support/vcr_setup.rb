# frozen_string_literal: true

require "vcr"
require "webmock/minitest"

VCR.configure do |config|
  config.cassette_library_dir = "test/cassettes"
  config.hook_into :webmock
  config.ignore_localhost = true

  config.allow_http_connections_when_no_cassette = false

  config.default_cassette_options = {
    record: :new_episodes,
    re_record_interval: 30.days
  }

  config.filter_sensitive_data("<PROWLARR_API_KEY>") { ENV["PROWLARR_API_KEY"] }
  config.filter_sensitive_data("<DOWNLOAD_CLIENT_PASSWORD>") { ENV["DOWNLOAD_CLIENT_PASSWORD"] }
end

module VCRHelper
  def with_cassette(name, options = {}, &block)
    default_options = ENV["VCR_RECORD"] == "true" ? {} : { record: :none }
    VCR.use_cassette(name, default_options.merge(options), &block)
  end
end
