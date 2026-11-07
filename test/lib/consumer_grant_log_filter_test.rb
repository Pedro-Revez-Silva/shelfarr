# frozen_string_literal: true

require "test_helper"

class ConsumerGrantLogFilterTest < ActiveSupport::TestCase
  test "every spelling Rack decodes to a grant key is redacted in the logged path" do
    {
      "grant=v" => "grant=[FILTERED]",
      "gr%61nt=v" => "gr%61nt=[FILTERED]",
      "GRANT=v" => "GRANT=[FILTERED]",
      "grant%5B%5D=v" => "grant%5B%5D=[FILTERED]",
      "grant[]=v" => "grant[]=[FILTERED]",
      "x[grant]=v" => "x[grant]=[FILTERED]",
      "+grant=v" => "+grant=[FILTERED]",
      "a=1&grant=v;b=2" => "a=1&grant=[FILTERED];b=2",
      "grant_type=device&granted=1&q=grant" => "grant_type=device&granted=1&q=grant",
      "gr%zznt=v&bare" => "gr%zznt=v&bare"
    }.each do |query, expected|
      assert_equal "/p?#{expected}", request(query).filtered_path, query
    end
    assert_equal "/p", request("").filtered_path
  end

  test "non UTF-8 keys cannot crash request logging" do
    assert_equal "/p?x%FF=1&grant=[FILTERED]", request("x%FF=1&grant=synthetic").filtered_path
  end

  private

  def request(query)
    ActionDispatch::Request.new(Rack::MockRequest.env_for("/p").merge(
      "QUERY_STRING" => query, "action_dispatch.parameter_filter" => Rails.application.config.filter_parameters
    ))
  end
end
