# frozen_string_literal: true

require "test_helper"
require "rack/mock"

class ConsumerBodyLimitTest < ActiveSupport::TestCase
  test "bodyless requests and exact-limit payloads arrive intact" do
    app = ConsumerBodyLimit.new(->(env) { [ 200, {}, [ env["rack.input"].read ] ] })
    assert_equal [ "" ], app.call(Rack::MockRequest.env_for("/api/consumer/v1/auth/revoke", method: "POST")).last
    bytes = "x" * 65_536
    assert_equal [ bytes ], app.call(Rack::MockRequest.env_for("/shelfarr/api/consumer/v1/auth/device", method: "POST", input: bytes)).last
  end

  test "oversized protocol bodies stop before Rails parsing and other uploads are untouched" do
    app = ConsumerBodyLimit.new(->(_) { raise "must not reach Rails" })
    status, = app.call(Rack::MockRequest.env_for("/api/consumer/v1/library/1/progress", method: "PUT", input: "x" * 65_537))
    assert_equal 413, status
    env = Rack::MockRequest.env_for("/uploads", method: "POST", input: "x" * 65_537)
    source = env["rack.input"]
    ConsumerBodyLimit.new(->(request) { assert_same source, request["rack.input"]; [ 200, {}, [] ] }).call(env)
  end
end
