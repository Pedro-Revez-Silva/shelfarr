# frozen_string_literal: true

require "test_helper"

class RackGemTest < ActiveSupport::TestCase
  test "activates rack 3.2.8 or newer and drops an invalid Host from generated URLs" do
    spec = Gem.loaded_specs.fetch("rack")

    assert_operator spec.version, :>=, Gem::Version.new("3.2.8")

    request = Rack::Request.new(Rack::MockRequest.env_for("/", "HTTP_HOST" => "evil.com@attacker"))

    assert_nil request.host
    assert_nil request.host_with_port
    assert_equal "http://example.org", request.base_url
    assert_equal "http://example.org/", request.url
  end
end
