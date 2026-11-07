# frozen_string_literal: true

require "test_helper"
require "rack/mock"

class KoboBodyLimitTest < ActiveSupport::TestCase
  test "bodyless protocol requests reach the controller instead of raising" do
    env = Rack::MockRequest.env_for("/kobo/device/v1/auth/device", method: "POST")
    assert_nil env["rack.input"]
    status, = KoboBodyLimit.new(->(request) { [ 400, {}, [ request["rack.input"].read ] ] }).call(env)
    assert_equal 400, status
  end

  test "bounded JSON arrives unchanged and over-limit bodies never reach Rails" do
    called = false
    app = KoboBodyLimit.new(->(env) { called = true; [ 200, {}, [ env["rack.input"].read ] ] })
    body = '{"ReadingStates":[]}'
    assert_equal [ body ], app.call(Rack::MockRequest.env_for("/kobo/device/v1/library/id/state", method: "PUT", input: body)).last
    called = false
    status, = app.call(Rack::MockRequest.env_for("/kobo/device/v1/auth/device", method: "POST", input: "x" * 65_537))
    assert_equal 413, status
    assert_not called
  end

  test "limit covers both mounted paths and the bare device endpoint" do
    %w[/kobo/device /shelfarr/kobo/device/v1/unknown].each do |path|
      env = Rack::MockRequest.env_for(path, method: "POST", input: "x" * 65_537)
      status, = KoboBodyLimit.new(->(_) { raise "body must not be parsed" }).call(env)
      assert_equal 413, status
    end
  end

  test "web uploads retain their original input stream and size" do
    env = Rack::MockRequest.env_for("/uploads", method: "POST", input: "x" * 65_537)
    original = env["rack.input"]
    app = KoboBodyLimit.new(->(request) { assert_same original, request["rack.input"]; [ 201, {}, [ request["rack.input"].read ] ] })
    assert_equal 65_537, app.call(env).last.sole.bytesize
  end
end
