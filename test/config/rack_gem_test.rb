# frozen_string_literal: true

require "test_helper"
require "rack/mock"

class RackGemTest < ActiveSupport::TestCase
  test "activates rack 3.2.8 or newer and does not return an invalid Host from host_with_port" do
    spec = Gem.loaded_specs.fetch("rack")

    assert_operator spec.version, :>=, Gem::Version.new("3.2.8")

    request = Rack::Request.new(Rack::MockRequest.env_for("/", "HTTP_HOST" => "evil.com@attacker"))

    assert_nil request.host
    assert_nil request.host_with_port
    assert_equal "http://example.org", request.base_url
    assert_equal "http://example.org/", request.url
  end
end
