# frozen_string_literal: true

require "test_helper"
require_relative "chrome_storage_reset"

class ChromeStorageResetTest < ActiveSupport::TestCase
  class Driver
    prepend ChromeStorageReset

    attr_reader :calls

    def initialize
      @calls = []
    end

    def execute_cdp(cmd, params = {})
      @calls << [ cmd, params ]
    end
  end

  test "wildcard storage reset clears cookies and the app server local storage" do
    server = Data.define(:base_url).new("http://127.0.0.1:3000")
    session = Data.define(:server).new(server)
    driver = Driver.new

    Capybara.stub(:current_session, session) do
      driver.send(
        :execute_cdp,
        "Storage.clearDataForOrigin",
        origin: "*",
        storageTypes: "cookies,local_storage"
      )
    end

    assert_equal [
      [ "Network.clearBrowserCookies", {} ],
      [ "Storage.clearDataForOrigin", { origin: "http://127.0.0.1:3000", storageTypes: "local_storage" } ]
    ], driver.calls
  end

  test "cdp commands other than the wildcard storage clear are unchanged" do
    driver = Driver.new

    driver.send(:execute_cdp, "Storage.clearDataForOrigin", origin: "http://127.0.0.1:3000", storageTypes: "cookies")

    assert_equal [
      [ "Storage.clearDataForOrigin", { origin: "http://127.0.0.1:3000", storageTypes: "cookies" } ]
    ], driver.calls
  end
end
