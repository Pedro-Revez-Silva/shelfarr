# frozen_string_literal: true

require "test_helper"

class ConsumerGrantQueryGuardTest < ActiveSupport::TestCase
  test "valid queries pass through unchanged" do
    [ "grant=synthetic", "&grant=synthetic", "q=hello", "" ].each do |query|
      observed = nil
      app = ConsumerGrantQueryGuard.new(->(env) { observed = env["QUERY_STRING"]; [ 204, {}, [] ] })
      assert_equal 204, app.call("QUERY_STRING" => query).first
      assert_equal query, observed
    end
  end

  test "malformed nested sensitive queries are rejected without dispatch" do
    app = ConsumerGrantQueryGuard.new(->(_) { flunk "malformed query reached Rails logging" })
    status, headers, body = app.call("PATH_INFO" => "/nowhere", "REQUEST_METHOD" => "GET",
      "QUERY_STRING" => "x[grant]=synthetic%FF")
    assert_equal 400, status
    assert_equal "private, no-store", headers["cache-control"]
    assert_equal [ '{"error":"invalid_request"}' ], body
  end
end
