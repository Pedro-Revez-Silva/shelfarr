# frozen_string_literal: true

require "test_helper"

class AndroidServerAddressTest < ActiveSupport::TestCase
  def address(url, script_name: "")
    env = Rack::MockRequest.env_for(url, "SCRIPT_NAME" => script_name)
    AndroidServerAddress.new(ActionDispatch::Request.new(env))
  end

  test "builds a percent-encoded HTTPS connect link with the subpath" do
    value = address("https://Books.Example.org/apps/android", script_name: "/shelfarr")

    assert_equal "https://books.example.org/shelfarr", value.to_s
    assert_equal "shelfarr://connect?server=https%3A%2F%2Fbooks.example.org%2Fshelfarr", value.connect_url
  end

  test "keeps a non-default port and omits the default one" do
    assert_equal "https://books.example.org:8443", address("https://books.example.org:8443/apps/android").to_s
    assert_equal "https://books.example.org", address("https://books.example.org:443/apps/android").to_s
  end

  test "offers nothing for plain HTTP or an unclean address" do
    [
      address("http://books.example.org/apps/android"),
      address("https://books.example.org/apps/android", script_name: "/a/../b"),
      address("https://books.example.org/apps/android", script_name: "/a/%2e%2e"),
      address("https://books.example.org/apps/android", script_name: "/shelfarr/")
    ].each do |value|
      assert_not value.usable?
      assert_equal "", value.to_s
      assert_nil value.connect_url
    end
  end
end
