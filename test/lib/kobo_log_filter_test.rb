# frozen_string_literal: true

require "test_helper"

class KoboLogFilterTest < ActiveSupport::TestCase
  test "reader queries are absent from the logged path without modifying the request" do
    path = "/books/kobo/synthetic-capability/v1/library/sync"
    query = "SerialNumber=synthetic-serial&ReaderHandle=synthetic-handle&unknown=value"
    request = ActionDispatch::Request.new(Rack::MockRequest.env_for("#{path}?#{query}").merge(
      "action_dispatch.parameter_filter" => Rails.application.config.filter_parameters))
    assert_equal "/books/kobo/[FILTERED]/v1/library/sync", request.filtered_path
    assert_equal "synthetic-serial", request.query_parameters.fetch("SerialNumber")
    assert_equal "#{path}?#{query}", request.fullpath
    request.path_parameters = { controller: "kobo", action: "sync", format: "json", kobo_token: "synthetic-capability" }
    assert_equal({ "controller" => "kobo", "action" => "sync", "format" => "json" }, request.filtered_parameters)
  end

  test "non-reader routes retain their ordinary filtered query strings" do
    request = ActionDispatch::Request.new(Rack::MockRequest.env_for("/read?q=fixture"))
    assert_equal "/read?q=fixture", request.filtered_path
  end
end
