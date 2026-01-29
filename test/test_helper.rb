ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require_relative "test_helpers/session_test_helper"
require_relative "support/vcr_setup"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Include VCR helper for all tests
    include VCRHelper

    # Helper to stub qBittorrent connection (auth + version endpoint)
    def stub_qbittorrent_connection(url, session_id: "test_session_id")
      stub_request(:post, "#{url}/api/v2/auth/login")
        .to_return(
          status: 200,
          headers: { "Set-Cookie" => "SID=#{session_id}; path=/" },
          body: "Ok."
        )

      stub_request(:get, "#{url}/api/v2/app/version")
        .to_return(status: 200, body: "v4.6.0")
    end

    # Add more helper methods to be used by all tests here...
  end
end
