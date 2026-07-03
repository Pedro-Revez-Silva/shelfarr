ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require "mutant/minitest/coverage"
require_relative "test_helpers/session_test_helper"
require_relative "support/vcr_setup"

# Resolve hostnames to a fixed public test address instead of doing real DNS
# lookups. Tests for OutboundUrlGuard itself swap the resolver as needed.
OutboundUrlGuard.resolver = ->(host) { [ "203.0.113.10" ] }

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors) unless ENV["COVERAGE"]

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Include VCR helper for all tests
    include VCRHelper

    # Helper to stub qBittorrent connection (auth + version + category + diagnostics)
    def stub_qbittorrent_connection(url, session_id: "test_session_id")
      stub_request(:post, "#{url}/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=#{session_id}; path=/" },
          body: "Ok."
        )

      stub_request(:get, "#{url}/api/v2/app/version")
        .to_return(status: 200, body: "v4.6.0")

      stub_request(:post, "#{url}/api/v2/torrents/createCategory")
        .to_return(status: 409)

      stub_request(:get, "#{url}/api/v2/app/preferences")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "save_path" => "/downloads" }.to_json
        )

      stub_request(:get, "#{url}/api/v2/torrents/categories")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {}.to_json
        )
    end

    def with_env(overrides)
      original = overrides.each_key.to_h { |key| [ key, ENV.key?(key) ? ENV[key] : :__unset__ ] }

      overrides.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end

      yield
    ensure
      original&.each do |key, value|
        value == :__unset__ ? ENV.delete(key) : ENV[key] = value
      end
    end

    def clear_settings_env!
      @settings_env_backup = ENV.to_h.select { |key, _| key.start_with?(SettingsService::ENV_OVERRIDE_PREFIX) }
      @settings_env_backup.each_key { |key| ENV.delete(key) }
    end

    def restore_settings_env!
      return unless defined?(@settings_env_backup) && @settings_env_backup

      ENV.delete_if { |key, _| key.start_with?(SettingsService::ENV_OVERRIDE_PREFIX) }
      @settings_env_backup.each { |key, value| ENV[key] = value }
      @settings_env_backup = nil
    end

    # Add more helper methods to be used by all tests here...
  end
end
